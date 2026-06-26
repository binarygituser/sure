# frozen_string_literal: true

module GocardlessItem::Unlinking
  extend ActiveSupport::Concern

  # Idempotently remove all connections between this GoCardless item and local accounts.
  def unlink_all!(dry_run: false)
    results = []

    gocardless_accounts.find_each do |gca|
      links = AccountProvider.where(provider_type: "GocardlessAccount", provider_id: gca.id).to_a
      link_ids = links.map(&:id)
      result = {
        gca_id: gca.id,
        name: gca.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          # Detach holdings for any provider links found
          if link_ids.any?
            Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil)
          end

          # Destroy all provider links
          links.each(&:destroy!)
        end
      rescue => e
        Rails.logger.warn(
          "GoCardlessItem Unlinker: failed to fully unlink GCA ##{gca.id} (links=#{link_ids.inspect}): #{e.class} - #{e.message}"
        )
        result[:error] = e.message
      end
    end

    results
  end
end
