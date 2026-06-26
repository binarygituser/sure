class GocardlessItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Encrypt sensitive credentials and raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :secret_key, deterministic: true
    encrypts :access_token, deterministic: true
    encrypts :refresh_token, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :country_code, presence: true
  validates :secret_id, presence: true
  validates :secret_key, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :gocardless_accounts, dependent: :destroy
  has_many :accounts, through: :gocardless_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def credentials_configured?
    secret_id.present? && secret_key.present? && country_code.present?
  end

  def session_valid?
    requisition_id.present? && access_token.present?
  end

  def session_expired?
    access_token_expires_at.present? && access_token_expires_at <= Time.current
  end

  def needs_authorization?
    !session_valid? || requisition_id.blank?
  end

  # ── authorization flow ──────────────────────────────────────────────

  # Get list of available banks for this item's country
  def fetch_institutions
    provider = gocardless_provider
    raise StandardError.new("GoCardless provider is not configured") unless provider

    result = provider.get_institutions(country: country_code)
    institutions = result.is_a?(Array) ? result : result[:institutions] || result["institutions"] || []

    # Sort: non-beta alphabetically, then beta alphabetically
    institutions.map(&:with_indifferent_access).sort_by { |i| [ i[:beta] ? 1 : 0, i[:name].to_s.downcase ] }
  end

  # Start the bank authorization flow
  # @param institution_id [String] GoCardless institution ID
  # @param redirect_url [String] Callback URL
  # @param reference [String, nil] Custom reference
  # @param user_language [String, nil] Two-letter language code
  # @return [String] Redirect URL for the user to authorize
  def start_authorization(institution_id:, redirect_url:, reference: nil, user_language: nil)
    provider = gocardless_provider
    raise StandardError.new("GoCardless provider is not configured") unless provider

    # Step 1: Create end user agreement
    agreement = provider.create_agreement(
      institution_id: institution_id,
      max_historical_days: 730,
      access_valid_for_days: 90,
      access_scope: %w[balances details transactions]
    )
    agreement_id = agreement[:id]

    # Step 2: Accept the agreement (required for requisition)
    begin
      provider.accept_agreement(
        id: agreement_id,
        user_agent: "SureFinance/1.0",
        ip_address: last_psu_ip || "0.0.0.0"
      )
    rescue Provider::Gocardless::GocardlessError => e
      Rails.logger.warn "GoCardless agreement acceptance failed (non-fatal): #{e.message}"
    end

    # Step 3: Create requisition
    requisition = provider.create_requisition(
      institution_id: institution_id,
      redirect: redirect_url,
      agreement: agreement_id,
      reference: reference || id,
      user_language: user_language
    )

    # Persist tokens and agreement/requisition IDs
    persist_tokens!(provider)

    update!(
      agreement_id: agreement_id,
      requisition_id: requisition[:id],
      institution_id: institution_id
    )

    requisition[:link]
  end

  # Complete authorization after user returns from bank
  def complete_authorization
    provider = gocardless_provider
    raise StandardError.new("GoCardless provider is not configured") unless provider

    # Get the requisition status to retrieve account IDs
    result = provider.get_requisition(id: requisition_id)

    # Persist tokens (may have been refreshed)
    persist_tokens!(provider)

    account_ids = result[:accounts] || []

    # Fetch and store details for each account
    account_ids.each do |account_id|
      account_data = provider.get_account(id: account_id)
      balance_data = begin
        provider.get_account_balances(id: account_id)
      rescue Provider::Gocardless::GocardlessError => e
        Rails.logger.warn "GoCardless: Could not fetch balances for account #{account_id}: #{e.message}"
        nil
      end

      upsert_gocardless_account!(account_data, balance_data)
    end

    update!(status: :good)

    result
  end

  # ── data import ──────────────────────────────────────────────────────

  def import_latest_gocardless_data
    provider = gocardless_provider
    unless provider
      Rails.logger.error "GocardlessItem #{id} - Cannot import: GoCardless provider is not configured"
      raise StandardError.new("GoCardless provider is not configured")
    end

    unless session_valid?
      Rails.logger.error "GocardlessItem #{id} - Cannot import: Session is not valid"
      update!(status: :requires_update)
      raise StandardError.new("GoCardless session is not valid or has expired")
    end

    GocardlessItem::Importer.new(self, gocardless_provider: provider).import
  rescue => e
    Rails.logger.error "GocardlessItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if gocardless_accounts.empty?

    results = []
    gocardless_accounts.joins(:account).merge(Account.visible).each do |gocardless_account|
      begin
        result = GocardlessAccount::Processor.new(gocardless_account).process
        results << { gocardless_account_id: gocardless_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "GocardlessItem #{id} - Failed to process account #{gocardless_account.id}: #{e.message}"
        results << { gocardless_account_id: gocardless_account.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "GocardlessItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  # ── account counts ───────────────────────────────────────────────────

  def has_completed_initial_setup?
    accounts.any?
  end

  def linked_accounts_count
    gocardless_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    gocardless_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    gocardless_accounts.count
  end

  def sync_status_summary
    latest = latest_sync
    return nil unless latest

    total = gocardless_accounts.count
    linked_count = accounts.count
    unlinked_count = total - linked_count

    if total == 0
      "No accounts found"
    elsif unlinked_count == 0
      "#{linked_count} #{'account'.pluralize(linked_count)} synced"
    else
      "#{linked_count} synced, #{unlinked_count} need setup"
    end
  end

  # ── delete / revoke ──────────────────────────────────────────────────

  def institution_display_name
    institution_name_selected.presence || institution_name.presence || institution_domain.presence || name
  end

  def revoke_requisition
    return unless requisition_id.present?

    provider = gocardless_provider
    return unless provider

    begin
      provider.delete_requisition(id: requisition_id)
    rescue Provider::Gocardless::GocardlessError => e
      Rails.logger.warn "GocardlessItem #{id} - Failed to delete requisition: #{e.message}"
    ensure
      update!(
        requisition_id: nil,
        agreement_id: nil,
        access_token: nil,
        refresh_token: nil,
        access_token_expires_at: nil
      )
    end
  end

  private

    def upsert_gocardless_account!(account_data, balance_data)
      data = account_data.with_indifferent_access
      account_id = data[:id]

      gocardless_account = gocardless_accounts.find_or_initialize_by(account_id: account_id)

      # Build institution metadata from account data
      institution_name = institution_name_selected || data.dig(:institution_id)

      gocardless_account.update!(
        name: build_account_name(data, institution_name),
        currency: parse_currency(data[:currency]) || "EUR",
        iban: data[:iban],
        account_type: data[:cash_account_type],
        account_status: data[:status],
        provider: "gocardless",
        institution_metadata: {
          name: institution_name,
          id: data[:institution_id]
        }.compact,
        raw_payload: account_data,
        # Balance data
        current_balance: balance_data&.dig(:balances, 0, :balance_amount, :amount),
        raw_payload: account_data
      )
    end

    def build_account_name(data, institution_name)
      if data[:name].present?
        data[:name]
      elsif data[:iban].present?
        "Account ...#{data[:iban][-4..]}"
      elsif data[:details].present?
        data[:details]
      else
        "#{institution_name || 'GoCardless'} Account"
      end
    end

    def parse_currency(currency_value)
      return nil if currency_value.blank?
      currency_value.to_s.upcase
    end
end
