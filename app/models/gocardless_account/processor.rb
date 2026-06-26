class GocardlessAccount::Processor
  class ProcessingError < StandardError; end
  include CurrencyNormalizable

  attr_reader :gocardless_account

  def initialize(gocardless_account)
    @gocardless_account = gocardless_account
  end

  def process
    unless gocardless_account.current_account.present?
      Rails.logger.info "GocardlessAccount::Processor - No linked account for gocardless_account #{gocardless_account.id}, skipping processing"
      return
    end

    Rails.logger.info "GocardlessAccount::Processor - Processing gocardless_account #{gocardless_account.id} (account_id #{gocardless_account.account_id})"

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "GocardlessAccount::Processor - Failed to process account #{gocardless_account.id}: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      report_exception(e, "account")
      raise
    end

    process_transactions
  end

  private

    def process_account!
      if gocardless_account.current_account.blank?
        Rails.logger.error("GoCardless account #{gocardless_account.id} has no associated Account")
        return
      end

      account = gocardless_account.current_account
      balance = gocardless_account.current_balance || 0
      available_credit = nil

      # For liability accounts, ensure balance sign is correct.
      # For CreditCards, display available credit (credit_limit - outstanding debt).
      if account.accountable_type == "Loan"
        balance = balance.abs
      elsif account.accountable_type == "CreditCard"
        if gocardless_account.respond_to?(:credit_limit) && gocardless_account.credit_limit.present?
          available = gocardless_account.credit_limit - balance.abs
          available_credit = [ available, 0 ].max
          balance = available_credit
        elsif account.accountable&.available_credit.present?
          Rails.logger.info "Using stored available_credit fallback for account #{account.id}"
          available_credit = account.accountable.available_credit
          outstanding = balance.abs
          balance = [ available_credit - outstanding, 0 ].max
        end
      end

      currency = parse_currency(gocardless_account.currency) || account.currency || "EUR"

      # Wrap both writes in a transaction so a failure on either rolls back both.
      ActiveRecord::Base.transaction do
        if account.accountable.present? && account.accountable.respond_to?(:available_credit=)
          account.accountable.update!(available_credit: available_credit)
        end
        account.update!(currency: currency, cash_balance: balance)

        # Use set_current_balance to create a current_anchor valuation entry.
        # This enables Balance::ReverseCalculator, which works backward from the
        # bank-reported balance — eliminating spurious cash adjustment spikes.
        result = account.set_current_balance(balance)
        raise ProcessingError, "Failed to set current balance: #{result.error}" unless result.success?
      end
    end

    def process_transactions
      GocardlessAccount::Transactions::Processor.new(gocardless_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          gocardless_account_id: gocardless_account.id,
          context: context
        )
      end
    end
end
