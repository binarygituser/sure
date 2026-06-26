class GocardlessItemsController < ApplicationController
  before_action :set_gocardless_item, only: [ :update, :destroy, :sync, :select_bank, :authorize, :reauthorize, :setup_accounts, :complete_account_setup, :new_connection ]
  before_action :require_admin!, only: [ :new, :create, :link_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :select_bank, :authorize, :reauthorize, :setup_accounts, :complete_account_setup, :new_connection ]
  skip_before_action :verify_authenticity_token, only: [ :callback ]

  def new
    @gocardless_item = Current.family.gocardless_items.build
  end

  def create
    @gocardless_item = Current.family.gocardless_items.build(gocardless_item_params)
    @gocardless_item.name ||= "GoCardless Connection"

    if @gocardless_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured GoCardless.")
        @gocardless_items = Current.family.gocardless_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "gocardless-providers-panel",
            partial: "settings/providers/gocardless_panel",
            locals: { gocardless_items: @gocardless_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @gocardless_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "gocardless-providers-panel",
          partial: "settings/providers/gocardless_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @gocardless_item.update(gocardless_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated GoCardless configuration.")
        @gocardless_items = Current.family.gocardless_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "gocardless-providers-panel",
            partial: "settings/providers/gocardless_panel",
            locals: { gocardless_items: @gocardless_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @gocardless_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "gocardless-providers-panel",
          partial: "settings/providers/gocardless_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    # Ensure we detach provider links before scheduling deletion
    begin
      @gocardless_item.unlink_all!(dry_run: false)
    rescue => e
      Rails.logger.warn("GoCardless unlink during destroy failed: #{e.class} - #{e.message}")
    end
    @gocardless_item.revoke_requisition
    @gocardless_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled GoCardless connection for deletion.")
  end

  def sync
    unless @gocardless_item.syncing?
      @gocardless_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Show bank selection page
  def select_bank
    unless @gocardless_item.credentials_configured?
      redirect_to settings_providers_path, alert: t(".credentials_required", default: "Please configure your GoCardless credentials first.")
      return
    end

    @new_connection = params[:new_connection] == "true"

    begin
      @institutions = @gocardless_item.fetch_institutions
    rescue Provider::Gocardless::GocardlessError => e
      Rails.logger.error "GoCardless API error in select_bank: #{e.message}"
      @error_message = e.message
      @institutions = []
    end

    render layout: false
  end

  # Initiate authorization for a selected bank
  def authorize
    institution_id = params[:institution_id]

    unless institution_id.present?
      redirect_to settings_providers_path, alert: t(".bank_required", default: "Please select a bank.")
      return
    end

    begin
      target_item = if params[:new_connection] == "true"
        Current.family.gocardless_items.create!(
          name: "GoCardless Connection",
          country_code: @gocardless_item.country_code,
          secret_id: @gocardless_item.secret_id,
          secret_key: @gocardless_item.secret_key
        )
      else
        @gocardless_item
      end

      # Store the institution name for display
      institution = params[:institution_name]
      target_item.update(institution_name_selected: institution) if institution.present?

      language = I18n.locale.to_s.split("-").first

      redirect_url = target_item.start_authorization(
        institution_id: institution_id,
        redirect_url: gocardless_callback_url,
        reference: target_item.id,
        user_language: language
      )

      safe_redirect_to_gocardless(
        redirect_url,
        fallback_path: settings_providers_path,
        fallback_alert: t(".invalid_redirect", default: "Invalid authorization URL received. Please try again.")
      )
    rescue Provider::Gocardless::GocardlessError => e
      Rails.logger.error "GoCardless authorization error: #{e.message}"
      redirect_to settings_providers_path, alert: t(".authorization_failed",
        default: "Failed to start authorization: %{message}", message: e.message)
    rescue => e
      Rails.logger.error "Unexpected error in authorize: #{e.class}: #{e.message}"
      redirect_to settings_providers_path, alert: t(".unexpected_error", default: "An unexpected error occurred. Please try again.")
    end
  end

  # Handle OAuth callback from GoCardless
  def callback
    ref = params[:ref]

    unless ref.present?
      redirect_to settings_providers_path, alert: t(".invalid_callback", default: "Invalid callback parameters.")
      return
    end

    # Find the gocardless_item by the reference (item ID)
    gocardless_item = Current.family.gocardless_items.find_by(id: ref)

    unless gocardless_item.present?
      redirect_to settings_providers_path, alert: t(".item_not_found", default: "Connection not found.")
      return
    end

    begin
      gocardless_item.complete_authorization

      # Trigger sync to process accounts
      gocardless_item.sync_later

      redirect_to accounts_path, notice: t(".success", default: "Successfully connected to your bank. Your accounts are being synced.")
    rescue Provider::Gocardless::GocardlessError => e
      Rails.logger.error "GoCardless completion error: #{e.message}"
      redirect_to settings_providers_path, alert: t(".session_failed", default: "Failed to complete authorization: %{message}", message: e.message)
    rescue => e
      Rails.logger.error "Unexpected error in callback: #{e.class}: #{e.message}"
      redirect_to settings_providers_path, alert: t(".unexpected_error", default: "An unexpected error occurred. Please try again.")
    end
  end

  # Show bank selection for a new connection using credentials from an existing item
  def new_connection
    redirect_to select_bank_gocardless_item_path(@gocardless_item, new_connection: true), data: { turbo_frame: "modal" }
  end

  # Re-authorize
  def reauthorize
    # Redirect to bank selection for re-authorization
    redirect_to select_bank_gocardless_item_path(@gocardless_item), data: { turbo_frame: "modal" }
  end

  # Link accounts from GoCardless to internal accounts
  def link_accounts
    selected_ids = params[:account_ids] || []
    accountable_type = params[:accountable_type] || "Depository"

    if selected_ids.empty?
      redirect_to accounts_path, alert: t(".no_accounts_selected", default: "No accounts selected.")
      return
    end

    gocardless_item = Current.family.gocardless_items.where.not(requisition_id: nil).first

    unless gocardless_item.present?
      redirect_to settings_providers_path, alert: t(".no_session", default: "No active GoCardless connection. Please connect a bank first.")
      return
    end

    created_accounts = []
    already_linked_accounts = []

    begin
      ActiveRecord::Base.transaction do
        selected_ids.each do |account_id|
          gocardless_account = gocardless_item.gocardless_accounts.find_by(account_id: account_id)
          next unless gocardless_account

          # Check if already linked
          if gocardless_account.account_provider.present?
            already_linked_accounts << gocardless_account.name
            next
          end

          # Create the internal Account
          account = Account.create_and_sync(
            {
              family: Current.family,
              name: gocardless_account.name,
              balance: gocardless_account.current_balance || 0,
              currency: gocardless_account.currency || "EUR",
              accountable_type: accountable_type,
              accountable_attributes: {}
            },
            skip_initial_sync: true
          )

          # Link account to gocardless_account via account_providers
          AccountProvider.create!(
            account: account,
            provider: gocardless_account
          )

          created_accounts << account
        end
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      Rails.logger.error "GoCardless link_accounts failed: #{e.class} - #{e.message}"
      redirect_to accounts_path, alert: t(".link_failed", default: "Failed to link accounts: %{error}", error: e.message)
      return
    end

    gocardless_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", default: "%{count} account(s) linked successfully.", count: created_accounts.count)
    elsif already_linked_accounts.any?
      redirect_to accounts_path, alert: t(".already_linked", default: "Selected accounts are already linked.")
    else
      redirect_to accounts_path, alert: t(".link_failed", default: "Failed to link accounts.")
    end
  end

  # Show setup accounts modal
  def setup_accounts
    @gocardless_accounts = @gocardless_item.gocardless_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    @account_type_options = [
      [ "Skip this account", "skip" ],
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Investment Account", "Investment" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ]
    ]

    @subtype_options = {
      "Depository" => {
        label: "Account Subtype:",
        options: Depository::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "CreditCard" => {
        label: "",
        options: [],
        message: "Credit cards will be automatically set up as credit card accounts."
      },
      "Investment" => {
        label: "Investment Type:",
        options: Investment::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "Loan" => {
        label: "Loan Type:",
        options: Loan::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "OtherAsset" => {
        label: nil,
        options: [],
        message: "Other assets will be set up as general assets."
      }
    }

    render layout: false
  end

  # Complete account setup from modal
  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    if params[:sync_start_date].present?
      @gocardless_item.update!(sync_start_date: params[:sync_start_date])
    end

    created_count = 0
    skipped_count = 0

    account_types.each do |gocardless_account_id, selected_type|
      if selected_type == "skip" || selected_type.blank?
        skipped_count += 1
        next
      end

      gocardless_account = @gocardless_item.gocardless_accounts.find(gocardless_account_id)
      selected_subtype = account_subtypes[gocardless_account_id]
      selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

      account = Account.create_and_sync(
        {
          family: Current.family,
          name: gocardless_account.name,
          balance: gocardless_account.current_balance || 0,
          currency: gocardless_account.currency || "EUR",
          accountable_type: selected_type,
          accountable_attributes: {}
        },
        skip_initial_sync: true
      )

      AccountProvider.create!(
        account: account,
        provider: gocardless_account
      )

      created_count += 1
    end

    @gocardless_item.update!(pending_account_setup: false)
    @gocardless_item.sync_later if created_count > 0

    if created_count > 0
      flash[:notice] = t(".success", default: "%{count} account(s) created successfully!", count: created_count)
    elsif skipped_count > 0
      flash[:notice] = t(".all_skipped", default: "All accounts were skipped. You can set them up later from the accounts page.")
    else
      flash[:notice] = t(".no_accounts", default: "No accounts to set up.")
    end

    redirect_to accounts_path, status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])

    @available_gocardless_accounts = Current.family.gocardless_items
      .includes(:gocardless_accounts)
      .flat_map(&:gocardless_accounts)
      .reject { |gca| gca.account_provider.present? || gca.account.present? }
      .sort_by { |gca| gca.updated_at || gca.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    gocardless_account = GocardlessAccount.find(params[:gocardless_account_id])

    if @account.account_providers.any?
      flash[:alert] = t("gocardless_items.link_existing_account.errors.only_manual")
      if turbo_frame_request?
        return render turbo_stream: Array(flash_notification_stream_items)
      else
        return redirect_to account_path(@account), alert: flash[:alert]
      end
    end

    unless gocardless_account.gocardless_item.present? &&
           Current.family.gocardless_items.include?(gocardless_account.gocardless_item)
      flash[:alert] = t("gocardless_items.link_existing_account.errors.invalid_gocardless_account")
      if turbo_frame_request?
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to account_path(@account), alert: flash[:alert]
      end
      return
    end

    Account.transaction do
      gocardless_account.lock!

      ap = AccountProvider.find_or_initialize_by(provider: gocardless_account)
      ap.account_id = @account.id
      ap.save!

      flash[:notice] = t("gocardless_items.link_existing_account.success",
        default: "Successfully linked %{name} to this account.", name: gocardless_account.name)
    end

    if turbo_frame_request?
      render turbo_stream: Array(flash_notification_stream_items)
    else
      redirect_to account_path(@account), notice: flash[:notice]
    end
  end

  private

    def set_gocardless_item
      @gocardless_item = Current.family.gocardless_items.find(params[:id])
    end

    def gocardless_item_params
      params.require(:gocardless_item).permit(:name, :country_code, :secret_id, :secret_key)
    end

    def gocardless_callback_url
      callback_gocardless_items_url
    end

    def safe_redirect_to_gocardless(url, fallback_path:, fallback_alert:)
      if url.present? && url.match?(%r{\Ahttps?://}i)
        redirect_to url, allow_other_host: true
      else
        redirect_to fallback_path, alert: fallback_alert
      end
    end
end
