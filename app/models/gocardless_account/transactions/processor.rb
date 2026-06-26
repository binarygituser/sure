class GocardlessAccount::Transactions::Processor
  attr_reader :gocardless_account

  def initialize(gocardless_account)
    @gocardless_account = gocardless_account
  end

  def process
    unless gocardless_account.raw_transactions_payload.present?
      Rails.logger.info "GocardlessAccount::Transactions::Processor - No transactions in raw_transactions_payload for gocardless_account #{gocardless_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    total_count = gocardless_account.raw_transactions_payload.count
    Rails.logger.info "GocardlessAccount::Transactions::Processor - Processing #{total_count} transactions for gocardless_account #{gocardless_account.id}"

    imported_count = 0
    skipped_count = 0
    failed_count = 0
    errors = []

    shared_adapter = if gocardless_account.current_account.present?
      Account::ProviderImportAdapter.new(gocardless_account.current_account)
    end

    # Pre-fetch external_ids that must not be re-imported.
    excluded_ids = if gocardless_account.current_account
      account_id = gocardless_account.current_account.id

      # 1. Manually merged: pending entries the user explicitly merged into a posted transaction.
      manually_merged_ids = Transaction.joins(:entry)
                                       .where(entries: { account_id: account_id })
                                       .where("transactions.extra ? 'manual_merge'")
                                       .joins(
                                         Arel.sql(<<~SQL.squish)
                                           CROSS JOIN LATERAL jsonb_array_elements(
                                             CASE jsonb_typeof(transactions.extra->'manual_merge')
                                             WHEN 'array'  THEN transactions.extra->'manual_merge'
                                             WHEN 'object' THEN jsonb_build_array(transactions.extra->'manual_merge')
                                             ELSE '[]'::jsonb
                                             END
                                           ) AS merge_elem
                                         SQL
                                       )
                                       .pluck(Arel.sql("merge_elem->>'merged_from_external_id'"))
                                       .compact
                                       .to_set

      # 2. Auto-claimed: pending entries that were automatically matched to a booked transaction.
      auto_claimed_ids = Transaction.joins(:entry)
                                    .where(entries: { account_id: account_id })
                                    .where("transactions.extra ? 'auto_claimed_pending_ids'")
                                    .joins(
                                      Arel.sql(<<~SQL.squish)
                                        CROSS JOIN LATERAL jsonb_array_elements_text(
                                          transactions.extra->'auto_claimed_pending_ids'
                                        ) AS claimed_id
                                      SQL
                                    )
                                    .pluck(Arel.sql("claimed_id"))
                                    .compact
                                    .to_set

      manually_merged_ids | auto_claimed_ids
    else
      Set.new
    end

    gocardless_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        ext_id = GocardlessTransaction::Processor.compute_external_id(transaction_data)

        if ext_id && excluded_ids.include?(ext_id)
          Rails.logger.info("GocardlessAccount::Transactions::Processor - Skipping re-import of manually merged pending transaction: #{ext_id}")
          skipped_count += 1
          next
        end

        result = GocardlessTransaction::Processor.new(
          transaction_data,
          gocardless_account: gocardless_account,
          import_adapter: shared_adapter
        ).process

        if result.nil?
          failed_count += 1
          errors << { index: index, transaction_id: transaction_data[:transactionId], error: "No linked account" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :transactionId) || transaction_data.try(:[], "transactionId") || "unknown"
        error_message = "Validation error: #{e.message}"
        Rails.logger.error "GocardlessAccount::Transactions::Processor - #{error_message} (transaction #{transaction_id})"
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      rescue => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :transactionId) || transaction_data.try(:[], "transactionId") || "unknown"
        error_message = "#{e.class}: #{e.message}"
        Rails.logger.error "GocardlessAccount::Transactions::Processor - Error processing transaction #{transaction_id}: #{error_message}"
        Rails.logger.error e.backtrace.join("\n")
        errors << { index: index, transaction_id: transaction_id, error: error_message }
      end
    end

    result = {
      success: failed_count == 0,
      total: total_count,
      imported: imported_count,
      skipped: skipped_count,
      failed: failed_count,
      errors: errors
    }

    if failed_count > 0
      Rails.logger.warn "GocardlessAccount::Transactions::Processor - Completed with #{failed_count} failures out of #{total_count} transactions"
    else
      Rails.logger.info "GocardlessAccount::Transactions::Processor - Successfully processed #{imported_count} transactions"
    end

    result
  end
end
