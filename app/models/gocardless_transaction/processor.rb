require "digest/md5"

class GocardlessTransaction::Processor
  include CurrencyNormalizable

  # GoCardless transaction structure (PSD2 / Berlin Group):
  # {
  #   transactionId, bookingDate, valueDate,
  #   transactionAmount: { amount, currency },
  #   creditorName, debtorName,
  #   remittanceInformationUnstructured,
  #   remittanceInformationUnstructuredArray,
  #   bankTransactionCode, internalTransactionId,
  #   additionalInformation, ...
  # }
  def self.compute_external_id(raw_transaction_data)
    data = raw_transaction_data.with_indifferent_access
    id = data[:transactionId].presence || data[:internalTransactionId].presence
    return "gocardless_#{id}" if id

    # Some banks omit transactionId. Generate a deterministic content-based ID
    # so these transactions can still be imported idempotently.
    date = data[:bookingDate].presence || data[:valueDate]
    amount = data.dig(:transactionAmount, :amount).presence || data[:amount]
    currency = data.dig(:transactionAmount, :currency).presence || data[:currency]
    creditor = data[:creditorName].presence
    debtor = data[:debtorName].presence
    remittance = data[:remittanceInformationUnstructured].presence ||
                 data.dig(:remittanceInformationUnstructuredArray, 0).presence

    content = [ date, amount, currency, creditor, debtor, remittance ].map(&:to_s).join("\x1F")
    return nil if content.gsub("\x1F", "").blank?

    "gocardless_content_#{Digest::MD5.hexdigest(content)}"
  end

  def initialize(gocardless_transaction, gocardless_account:, import_adapter: nil)
    @gocardless_transaction = gocardless_transaction
    @gocardless_account = gocardless_account
    @import_adapter = import_adapter
  end

  def process
    safe_id = self.class.compute_external_id(@gocardless_transaction) || "unknown"

    unless account.present?
      Rails.logger.warn "GocardlessTransaction::Processor - No linked account for gocardless_account #{gocardless_account.id}, skipping transaction #{safe_id}"
      return nil
    end

    begin
      import_adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: currency,
        date: date,
        name: name,
        source: "gocardless",
        merchant: merchant,
        notes: notes,
        extra: extra
      )
    rescue ArgumentError => e
      Rails.logger.error "GocardlessTransaction::Processor - Validation error for transaction #{safe_id}: #{e.message}"
      raise
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error "GocardlessTransaction::Processor - Failed to save transaction #{safe_id}: #{e.message}"
      raise StandardError.new("Failed to import transaction: #{e.message}")
    rescue => e
      Rails.logger.error "GocardlessTransaction::Processor - Unexpected error processing transaction #{safe_id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise StandardError.new("Unexpected error importing transaction: #{e.message}")
    end
  end

  private

    attr_reader :gocardless_transaction, :gocardless_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= gocardless_account.current_account
    end

    def data
      @data ||= gocardless_transaction.with_indifferent_access
    end

    def external_id
      id = self.class.compute_external_id(data)
      raise ArgumentError, "GoCardless transaction missing required identifier (transactionId, internalTransactionId, or identifiable content)" unless id
      id
    end

    def name
      counterparty = counterparty_name
      return counterparty if counterparty.present? && !technical_card_counterparty?(counterparty)

      if technical_card_counterparty?(counterparty)
        remittance = primary_remittance_information
        return remittance.truncate(100) if remittance.present?
      end

      # Fall back to remittance information
      remittance = primary_remittance_information
      return remittance.truncate(100) if remittance.present?

      # Fall back to bank transaction code description
      bank_tx_code = data[:bankTransactionCode]
      return bank_tx_code if bank_tx_code.present?

      # Final fallback
      transaction_direction == :credit ? "Incoming Transfer" : "Outgoing Transfer"
    end

    def merchant
      merchant_name = merchant_name_candidate
      return nil if merchant_name.blank?

      merchant_id = Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= begin
        import_adapter.find_or_create_merchant(
          provider_merchant_id: "gocardless_merchant_#{merchant_id}",
          name: merchant_name,
          source: "gocardless"
        )
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error "GocardlessTransaction::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
        nil
      end
    end

    def notes
      parts = []

      remittance = data[:remittanceInformationUnstructured]
      if remittance.present?
        parts << remittance
      end

      remittance_array = data[:remittanceInformationUnstructuredArray]
      if remittance_array.is_a?(Array) && remittance_array.any?
        parts.concat(remittance_array)
      end

      parts << data[:additionalInformation] if data[:additionalInformation].present?

      parts.join("\n\n").presence
    end

    def extra
      gc = {}

      # Pending flag
      gc[:pending] = true if data[:_pending] == true

      # Store bank transaction code for reference
      gc[:bank_transaction_code] = data[:bankTransactionCode] if data[:bankTransactionCode].present?

      # Store the internal transaction ID
      gc[:internal_transaction_id] = data[:internalTransactionId] if data[:internalTransactionId].present?

      # Store exchange rate info if present
      if data[:currencyExchange].present?
        exchange = data[:currencyExchange].with_indifferent_access
        gc[:fx_rate] = exchange[:exchangeRate] if exchange[:exchangeRate].present?
        gc[:fx_source_currency] = exchange[:sourceCurrency] if exchange[:sourceCurrency].present?
        gc[:fx_target_currency] = exchange[:targetCurrency] if exchange[:targetCurrency].present?
      end

      gc.compact!
      gc.empty? ? nil : { gocardless: gc }
    end

    def amount_value
      @amount_value ||= begin
        tx_amount = data[:transactionAmount] || {}
        raw_amount = tx_amount[:amount] || data[:amount] || "0"

        absolute_amount = case raw_amount
        when String
          BigDecimal(raw_amount).abs
        when Numeric
          BigDecimal(raw_amount.to_s).abs
        else
          BigDecimal("0")
        end

        # Sure convention: positive = outflow (debit/expense), negative = inflow (credit/income)
        # GoCardless PSD2: transactionAmount.amount is always signed (negative = debit, positive = credit)
        # But some banks send unsigned amounts. We detect direction:
        # - If amount string starts with '-', it's a debit (outflow)
        # - If creditorName is present, the money went TO them = debit (outflow) = positive
        # - If debtorName is present, the money came FROM them = credit (inflow) = negative
        raw_str = raw_amount.to_s

        if raw_str.start_with?("-")
          # Signed negative = debit from account = outflow
          absolute_amount
        elsif data[:creditorName].present?
          # We paid someone (creditor) = outflow
          absolute_amount
        elsif data[:debtorName].present?
          # Someone paid us (debtor) = inflow
          -absolute_amount
        else
          # Default: assume outflow
          absolute_amount
        end
      rescue ArgumentError => e
        Rails.logger.error "Failed to parse GoCardless transaction amount: #{raw_amount.inspect} - #{e.message}"
        raise
      end
    end

    def transaction_direction
      raw_str = data.dig(:transactionAmount, :amount).to_s
      if raw_str.start_with?("-")
        :debit
      elsif data[:creditorName].present?
        :debit
      elsif data[:debtorName].present?
        :credit
      else
        :debit
      end
    end

    def counterparty_name
      if transaction_direction == :credit
        data[:debtorName].presence
      else
        data[:creditorName].presence
      end
    end

    def technical_card_counterparty?(value)
      value.to_s.strip.match?(/\ACARD-\d+\z/i)
    end

    def primary_remittance_information
      data[:remittanceInformationUnstructured].presence ||
        Array.wrap(data[:remittanceInformationUnstructuredArray])
          .map { |v| v.to_s.strip.presence }
          .compact
          .first
    end

    def merchant_name_candidate
      counterparty = counterparty_name.to_s.strip
      return counterparty if counterparty.present? && !technical_card_counterparty?(counterparty)
      remittance = primary_remittance_information
      return remittance.truncate(100, omission: "") if remittance.present? && technical_card_counterparty?(counterparty)
      nil
    end

    def amount
      amount_value
    end

    def currency
      tx_amount = data[:transactionAmount] || {}
      parse_currency(tx_amount[:currency]) || parse_currency(data[:currency]) || account&.currency || "EUR"
    end

    def date
      date_value = data[:bookingDate] || data[:valueDate]

      case date_value
      when String
        Date.parse(date_value)
      when Date
        date_value
      else
        Rails.logger.error("GoCardless transaction has invalid date value: #{date_value.inspect}")
        raise ArgumentError, "Invalid date format: #{date_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse GoCardless transaction date '#{date_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{date_value.inspect}"
    end
end
