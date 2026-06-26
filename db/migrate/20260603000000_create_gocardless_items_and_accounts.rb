class CreateGocardlessItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    # Create provider items table (stores per-family connection credentials)
    create_table :gocardless_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      # Institution metadata
      t.string :institution_id
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      # Status and lifecycle
      t.string :status, default: "good"
      t.boolean :scheduled_for_deletion, default: false
      t.boolean :pending_account_setup, default: false

      # Sync settings
      t.datetime :sync_start_date

      # Raw data storage
      t.jsonb :raw_payload
      t.jsonb :raw_institution_payload

      # GoCardless credentials (encrypted at application level)
      t.string :secret_id
      t.text :secret_key

      # OAuth2 tokens
      t.string :access_token
      t.string :refresh_token
      t.datetime :access_token_expires_at

      # Requisition flow fields
      t.string :requisition_id
      t.string :agreement_id
      t.string :country_code

      # Bank selection
      t.string :institution_name_selected  # Institution name chosen by user

      t.timestamps
    end

    add_index :gocardless_items, :status

    # Create provider accounts table (stores individual account data from provider)
    create_table :gocardless_accounts, id: :uuid do |t|
      t.references :gocardless_item, null: false, foreign_key: true, type: :uuid

      # Account identification
      t.string :name
      t.string :account_id  # GoCardless account UUID

      # Account details
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type  # PSD2 cash account type
      t.string :provider
      t.string :iban

      # Metadata and raw data
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :gocardless_accounts, :account_id
  end
end
