module Family::GocardlessConnectable
  extend ActiveSupport::Concern

  included do
    has_many :gocardless_items, dependent: :destroy
  end

  def can_connect_gocardless?
    true
  end

  def create_gocardless_item!(country_code:, secret_id:, secret_key:, item_name: nil)
    gocardless_item = gocardless_items.create!(
      name: item_name || "GoCardless Connection",
      country_code: country_code,
      secret_id: secret_id,
      secret_key: secret_key
    )

    gocardless_item
  end

  def has_gocardless_credentials?
    gocardless_items.where.not(secret_id: nil).exists?
  end

  def has_gocardless_session?
    gocardless_items.where.not(requisition_id: nil).exists?
  end
end
