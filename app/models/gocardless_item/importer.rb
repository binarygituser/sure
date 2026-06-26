class GocardlessItem::Importer
  NETWORK_ERRORS = [
    ::SocketError,
    ::Errno::ECONNREFUSED,
    ::Timeout::Error,
    ::Net::ReadTimeout,
    ::Net::OpenTimeout
  ].freeze

  attr_reader :gocardless_item, :gocardless_provider

  def initialize(gocardless_item, gocardless_provider:)
    @gocardless_item = gocardless_item
    @gocardless_provider = gocardless_provider
  end

  def import
    unless gocardless_item.session_valid?
      gocardless_item.update!(status: :requires_update)
      return { success: false, error: I18n.t("gocardless_items.errors.session_invalid"), accounts_updated: 0, transactions_imported: 0 }
    end

    # Refresh account data for all linked accounts
    accounts_updated = 0
    accounts_failed = 0

    linked_accounts_query = gocardless_item.gocardless_accounts
      .joins(:account_provider)
      .joins(:account)
      .merge(Account.visible)

    linked_accounts_query.each do |gocardless_account|
      begin
        # Fetch and update account details
        account_data = gocardless_provider.get_account(id: gocardless_account.account_id)
        gocardless_account.upsert_gocardless_snapshot!(account_data)
        accounts_updated += 1
      rescue => e
        accounts_failed += 1
        @sync_error = promote_session_invalid(@sync_error, handle_sync_error(e))
        Rails.logger.error "GocardlessItem::Importer - Failed to update account #{gocardless_account.account_id}: #{e.message}"
      end
    end

    # Fetch balances and transactions for linked accounts
    transactions_imported = 0
    transactions_failed = 0

    linked_accounts_query.each do |gocardless_account|
      begin
        unless fetch_and_update_balance(gocardless_account)
          transactions_failed += 1
          next
        end

        result = fetch_and_store_transactions(gocardless_account)
        if result[:success]
          transactions_imported += result[:transactions_count]
        else
          transactions_failed += 1
          @sync_error = promote_session_invalid(@sync_error, result[:error])
        end
      rescue => e
        transactions_failed += 1
        @sync_error = promote_session_invalid(@sync_error, handle_sync_error(e))
        Rails.logger.error "GocardlessItem::Importer - Failed to process account #{gocardless_account.account_id}: #{e.class} - #{e.message}"
      end
    end

    result = {
      success: accounts_failed == 0 && transactions_failed == 0,
      accounts_updated: accounts_updated,
      accounts_failed: accounts_failed,
      transactions_imported: transactions_imported,
      transactions_failed: transactions_failed
    }

    result[:error] = @sync_error || I18n.t("gocardless_items.errors.unexpected") if !result[:success]
    result
  end

  private

    def handle_sync_error(exception)
      exceptions = [ exception.cause, exception ].compact

      provider_error = exceptions.find { |ex| ex.is_a?(Provider::Gocardless::GocardlessError) }

      if provider_error && [ :unauthorized, :not_found ].include?(provider_error.error_type)
        gocardless_item.update!(status: :requires_update)
        return I18n.t("gocardless_items.errors.session_invalid")
      end

      is_network_error = exceptions.any? do |ex|
        NETWORK_ERRORS.any? { |err| ex.is_a?(err) } ||
          (ex.is_a?(Provider::Gocardless::GocardlessError) && [ :request_failed, :timeout ].include?(ex.error_type))
      end

      if is_network_error
        I18n.t("gocardless_items.errors.network_unreachable")
      elsif provider_error
        I18n.t("gocardless_items.errors.api_error")
      else
        I18n.t("gocardless_items.errors.unexpected")
      end
    end

    def promote_session_invalid(existing, new)
      return new if existing.nil?
      return new if new == I18n.t("gocardless_items.errors.session_invalid")
      existing
    end

    def fetch_and_update_balance(gocardless_account)
      balance_data = gocardless_provider.get_account_balances(id: gocardless_account.account_id)

      # GoCardless returns an array of balances. Priority:
      # interimAvailable > interimBooked > closingBooked > expected > openingBooked
      balances = balance_data[:balances] || []
      return true if balances.empty?

      priority_types = [ "interimAvailable", "interimBooked", "closingBooked", "expected", "openingBooked" ]
      balance = nil

      priority_types.each do |type|
        balance = balances.find { |b| b[:balanceType] == type }
        break if balance
      end

      balance ||= balances.first

      if balance.present?
        amount = balance.dig(:balanceAmount, :amount) || balance[:amount]
        currency = balance.dig(:balanceAmount, :currency) || balance[:currency]

        if amount.present?
          parsed_amount = amount.to_d

          # GoCardless amounts may be signed (negative = debit/overdraft).
          # We store the raw signed value — the account processor handles sign correction
          # for liability accounts (CreditCard, Loan).
          gocardless_account.update!(
            current_balance: parsed_amount,
            currency: currency.presence || gocardless_account.currency
          )
        end
      end
      true
    rescue Provider::Gocardless::GocardlessError => e
      @sync_error = promote_session_invalid(@sync_error, handle_sync_error(e))
      Rails.logger.error "GocardlessItem::Importer - Error fetching balance for account #{gocardless_account.account_id}: #{e.message}"
      false
    end

    def include_pending?
      Setting.syncs_include_pending
    end

    def fetch_and_store_transactions(gocardless_account)
      start_date = determine_sync_start_date(gocardless_account)
      include_pending = include_pending?

      # GoCardless returns booked + pending in a single call.
      # Response shape: { transactions: { booked: [...], pending: [...] } }
      transactions_data = gocardless_provider.get_account_transactions(
        id: gocardless_account.account_id,
        date_from: start_date
      )

      transactions_wrapper = transactions_data[:transactions] || {}
      booked_transactions = transactions_wrapper[:booked] || []
      pending_transactions = transactions_wrapper[:pending] || []

      # Filter pending transactions if setting is disabled
      pending_transactions = [] unless include_pending

      # De-duplicate: remove pending txns that already have a booked match
      book_fingerprints = booked_transactions
        .map { |tx| GocardlessTransaction::Processor.compute_external_id(tx) }
        .compact.to_set

      pending_transactions.reject! do |tx|
        fp = GocardlessTransaction::Processor.compute_external_id(tx)
        fp.present? && book_fingerprints.include?(fp)
      end

      all_transactions = booked_transactions + tag_as_pending(pending_transactions)

      # Deduplicate API response
      all_transactions = deduplicate_api_transactions(all_transactions)

      # Post-fetch safety filter: some banks return transactions outside the date range
      all_transactions = filter_transactions_by_date(all_transactions, start_date)

      transactions_count = all_transactions.count

      existing_transactions = gocardless_account.raw_transactions_payload.to_a

      removed_pending = false
      unless include_pending
        removed_pending = existing_transactions.reject! do |tx|
          tx = tx.with_indifferent_access
          tx.dig(:extra, :gocardless, :pending) || tx[:_pending]
        end
      end

      if all_transactions.any?
        # Remove stored pending entries that have now settled as booked
        book_fingerprints = all_transactions
          .reject { |tx| tx.with_indifferent_access[:_pending] }
          .map { |tx| GocardlessTransaction::Processor.compute_external_id(tx) }
          .compact.to_set

        if include_pending
          removed_pending ||= existing_transactions.reject! do |tx|
            tx = tx.with_indifferent_access
            pending_flag = tx.dig(:extra, :gocardless, :pending) || tx[:_pending]
            next false unless pending_flag

            fp = GocardlessTransaction::Processor.compute_external_id(tx)
            fp.present? && book_fingerprints.include?(fp)
          end
        end

        existing_ids = existing_transactions.map { |tx|
          GocardlessTransaction::Processor.compute_external_id(tx)
        }.compact.to_set

        new_transactions = all_transactions.select do |tx|
          ext_id = GocardlessTransaction::Processor.compute_external_id(tx)
          ext_id.present? && !existing_ids.include?(ext_id)
        end

        if new_transactions.any? || removed_pending
          gocardless_account.upsert_gocardless_transactions_snapshot!(existing_transactions + new_transactions)
        end
      elsif removed_pending
        gocardless_account.upsert_gocardless_transactions_snapshot!(
          existing_transactions
        )
      end

      { success: true, transactions_count: transactions_count }
    rescue Provider::Gocardless::GocardlessError => e
      Rails.logger.error "GocardlessItem::Importer - Error fetching transactions for account #{gocardless_account.account_id}: #{e.message}"
      { success: false, transactions_count: 0, error: handle_sync_error(e) }
    rescue => e
      Rails.logger.error "GocardlessItem::Importer - Unexpected error fetching transactions for account #{gocardless_account.account_id}: #{e.class} - #{e.message}"
      { success: false, transactions_count: 0, error: handle_sync_error(e) }
    end

    def deduplicate_api_transactions(transactions)
      seen = {}
      duplicates_removed = 0

      result = transactions.select do |tx|
        tx = tx.with_indifferent_access
        key = build_transaction_content_key(tx)

        if seen[key]
          duplicates_removed += 1
          false
        else
          seen[key] = true
          true
        end
      end

      if duplicates_removed > 0
        Rails.logger.info(
          "GocardlessItem::Importer - Removed #{duplicates_removed} content-level " \
          "duplicate(s) from API response (#{transactions.count} → #{result.count} transactions)"
        )
      end

      result
    end

    def build_transaction_content_key(tx)
      date = tx[:bookingDate].presence || tx[:valueDate]
      amount = tx.dig(:transactionAmount, :amount).presence || tx[:amount]
      currency = tx.dig(:transactionAmount, :currency).presence || tx[:currency]
      creditor = tx[:creditorName].presence
      debtor = tx[:debtorName].presence
      remittance = tx[:remittanceInformationUnstructured].presence ||
                   tx.dig(:remittanceInformationUnstructuredArray, 0).presence
      tid = tx[:transactionId]
      internal_tid = tx[:internalTransactionId]

      [ date, amount, currency, creditor, debtor, remittance.to_s, tid, internal_tid ].map(&:to_s).join("\x1F")
    end

    def filter_transactions_by_date(transactions, start_date)
      return transactions unless start_date

      transactions.reject do |tx|
        tx = tx.with_indifferent_access
        date_str = tx[:bookingDate] || tx[:valueDate]
        next false if date_str.blank?

        begin
          Date.parse(date_str.to_s) < start_date
        rescue ArgumentError
          false
        end
      end
    end

    def tag_as_pending(transactions)
      transactions.map { |tx| tx.merge(_pending: true) }
    end

    def determine_sync_start_date(gocardless_account)
      has_stored_transactions = gocardless_account.raw_transactions_payload.to_a.any?

      user_start_date = gocardless_item.sync_start_date

      if has_stored_transactions
        if gocardless_item.last_synced_at
          gocardless_item.last_synced_at.to_date - 7.days
        else
          30.days.ago.to_date
        end
      else
        user_start_date || 3.months.ago.to_date
      end
    end
end
