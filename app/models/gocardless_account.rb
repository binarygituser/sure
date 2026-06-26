class GocardlessAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :gocardless_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :account_id, presence: true, uniqueness: { scope: :gocardless_item_id }

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Map PSD2 cash_account_type codes to user-friendly names
  def account_type_display
    return nil unless account_type.present?

    type_mappings = {
      "CACC" => "Current/Checking Account",
      "SVGS" => "Savings Account",
      "CARD" => "Card Account",
      "CRCD" => "Credit Card",
      "LOAN" => "Loan Account",
      "MORT" => "Mortgage Account",
      "ODFT" => "Overdraft Account",
      "CASH" => "Cash Account",
      "TRAN" => "Transacting Account",
      "SALA" => "Salary Account",
      "MOMA" => "Money Market Account",
      "NREX" => "Non-Resident External Account",
      "TAXE" => "Tax Account",
      "TRAS" => "Cash Trading Account",
      "ONDP" => "Overnight Deposit"
    }

    type_mappings[account_type.upcase] || account_type.titleize
  end

  CASH_ACCOUNT_TYPE_MAP = {
    "CACC" => { type: "Depository", subtype: "checking" },
    "SVGS" => { type: "Depository", subtype: "savings" },
    "CARD" => { type: "CreditCard", subtype: "credit_card" },
    "CRCD" => { type: "CreditCard", subtype: "credit_card" },
    "LOAN" => { type: "Loan",       subtype: nil },
    "MORT" => { type: "Loan",       subtype: "mortgage" },
    "ODFT" => { type: "Depository", subtype: "checking" },
    "TRAN" => { type: "Depository", subtype: "checking" },
    "SALA" => { type: "Depository", subtype: "checking" },
    "MOMA" => { type: "Depository", subtype: "savings" },
    "NREX" => { type: "Depository", subtype: "checking" },
    "TAXE" => { type: "Depository", subtype: "checking" },
    "TRAS" => { type: "Depository", subtype: "checking" },
    "ONDP" => { type: "Depository", subtype: "savings" },
    "CASH" => { type: "Depository", subtype: "checking" },
    "OTHR" => nil
  }.freeze

  def suggested_account_type
    CASH_ACCOUNT_TYPE_MAP[account_type&.upcase]&.dig(:type)
  end

  def suggested_subtype
    CASH_ACCOUNT_TYPE_MAP[account_type&.upcase]&.dig(:subtype)
  end

  def upsert_gocardless_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    update!(
      name: snapshot[:name] || "GoCardless Account",
      currency: parse_currency(snapshot[:currency]) || "EUR",
      iban: snapshot[:iban],
      account_type: snapshot[:cash_account_type] || snapshot[:account_type],
      account_status: snapshot[:status] || "active",
      provider: "gocardless",
      institution_metadata: {
        name: gocardless_item&.institution_name,
        id: snapshot[:institution_id]
      }.compact,
      raw_payload: account_snapshot
    )
  end

  def upsert_gocardless_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )
    save!
  end

  private

    def parse_currency(currency_value)
      return nil if currency_value.blank?
      currency_value.to_s.upcase
    end
end
