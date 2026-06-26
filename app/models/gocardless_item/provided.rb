module GocardlessItem::Provided
  extend ActiveSupport::Concern

  def gocardless_provider
    return nil unless credentials_configured?

    provider = Provider::Gocardless.new(
      secret_id: secret_id,
      secret_key: secret_key
    )

    # Restore tokens if available
    if access_token.present?
      provider.restore_tokens(
        access_token: access_token,
        refresh_token: refresh_token,
        access_token_expires_at: access_token_expires_at
      )
    end

    provider
  end

  # Persist tokens from the provider back to the item record
  def persist_tokens!(provider)
    update!(
      access_token: provider.current_access_token,
      refresh_token: provider.current_refresh_token,
      access_token_expires_at: provider.access_token_expires_at
    )
  end
end
