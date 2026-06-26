class Provider::GocardlessAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("GocardlessAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    %w[Depository CreditCard Loan]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_gocardless?

    [ {
      key: "gocardless",
      name: "GoCardless",
      description: "Connect to your bank via GoCardless (EU/UK open banking)",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_gocardless_item_path(
          accountable_type: accountable_type
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_gocardless_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  def provider_name
    "gocardless"
  end

  # Build a GoCardless provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::Gocardless, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    gocardless_item = family.gocardless_items.where.not(secret_id: nil).first
    return nil unless gocardless_item&.credentials_configured?

    provider = Provider::Gocardless.new(
      secret_id: gocardless_item.secret_id,
      secret_key: gocardless_item.secret_key
    )

    # Restore tokens if available
    if gocardless_item.access_token.present?
      provider.restore_tokens(
        access_token: gocardless_item.access_token,
        refresh_token: gocardless_item.refresh_token,
        access_token_expires_at: gocardless_item.access_token_expires_at
      )
    end

    provider
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_gocardless_item_path(item)
  end

  def item
    provider_account.gocardless_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["domain"]
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
