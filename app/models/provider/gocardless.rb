require "cgi"

class Provider::Gocardless
  include HTTParty
  extend SslConfigurable

  BASE_URL = "https://bankaccountdata.gocardless.com/api/v2".freeze

  headers "User-Agent" => "Sure Finance GoCardless Client"
  default_options.merge!({ timeout: 120 }.merge(httparty_ssl_options))

  attr_reader :secret_id, :secret_key

  def initialize(secret_id:, secret_key:)
    @secret_id = secret_id
    @secret_key = secret_key
    @access_token = nil
    @access_token_expires_at = nil
    @refresh_token = nil
  end

  # ── token management ──────────────────────────────────────────────

  # Obtain a new JWT pair (access + refresh tokens)
  def obtain_tokens
    response = self.class.post(
      "#{BASE_URL}/token/new/",
      headers: base_headers.merge("Content-Type" => "application/json"),
      body: { secret_id: secret_id, secret_key: secret_key }.to_json
    )
    data = handle_response(response)
    store_tokens(data)
    data
  end

  # Refresh the access token
  def refresh_access_token
    raise GocardlessError.new("No refresh token available", :no_refresh_token) unless @refresh_token

    response = self.class.post(
      "#{BASE_URL}/token/refresh/",
      headers: base_headers.merge("Content-Type" => "application/json"),
      body: { refresh: @refresh_token }.to_json
    )
    data = handle_response(response)
    store_tokens(data)
    data
  end

  def store_tokens(data)
    @access_token = data[:access]
    @access_token_expires_at = data[:access_expires] ? Time.current + data[:access_expires].seconds : nil
    @refresh_token = data[:refresh] if data[:refresh].present?
  end

  # Expose tokens for persistence
  def current_access_token
    ensure_valid_token
    @access_token
  end

  def current_refresh_token
    @refresh_token
  end

  def access_token_expires_at
    @access_token_expires_at
  end

  # Restore tokens from persistent storage
  def restore_tokens(access_token:, refresh_token:, access_token_expires_at: nil)
    @access_token = access_token
    @refresh_token = refresh_token
    @access_token_expires_at = access_token_expires_at
  end

  # ── institutions ──────────────────────────────────────────────────

  # Get list of available institutions (banks) for a country
  # @param country [String] ISO 3166-1 alpha-2 country code (e.g., "GB", "DE", "FR")
  # @return [Array<Hash>] List of institutions
  def get_institutions(country:)
    query = { country: country }
    response = self.class.get(
      "#{BASE_URL}/institutions/",
      headers: auth_headers,
      query: query
    )
    handle_response(response)
  end

  # Get details for a specific institution
  # @param institution_id [String] The institution ID
  # @return [Hash] Institution details
  def get_institution(institution_id:)
    response = self.class.get(
      "#{BASE_URL}/institutions/#{institution_id}/",
      headers: auth_headers
    )
    handle_response(response)
  end

  # ── end user agreements ───────────────────────────────────────────

  # Create an end user agreement
  # @param institution_id [String] Institution ID
  # @param max_historical_days [Integer] Max days of transaction history (1-730, default: 90)
  # @param access_valid_for_days [Integer] Days access is valid (1-730, default: 90)
  # @param access_scope [Array<String>] e.g., ["balances", "details", "transactions"]
  # @return [Hash] Created agreement
  def create_agreement(institution_id:, max_historical_days: 90, access_valid_for_days: 90,
                       access_scope: %w[balances details transactions])
    body = {
      institution_id: institution_id,
      max_historical_days: max_historical_days,
      access_valid_for_days: access_valid_for_days,
      access_scope: access_scope
    }
    response = self.class.post(
      "#{BASE_URL}/agreements/enduser/",
      headers: auth_headers.merge("Content-Type" => "application/json"),
      body: body.to_json
    )
    handle_response(response)
  end

  # Accept an end user agreement
  # @param id [String] Agreement UUID
  # @param user_agent [String] End user's User-Agent header
  # @param ip_address [String] End user's IP address
  # @return [Hash] Accepted agreement
  def accept_agreement(id:, user_agent:, ip_address:)
    body = { user_agent: user_agent, ip_address: ip_address }
    response = self.class.put(
      "#{BASE_URL}/agreements/enduser/#{id}/accept/",
      headers: auth_headers.merge("Content-Type" => "application/json"),
      body: body.to_json
    )
    handle_response(response)
  end

  # Get an agreement by ID
  # @param id [String] Agreement UUID
  # @return [Hash] Agreement details
  def get_agreement(id:)
    response = self.class.get(
      "#{BASE_URL}/agreements/enduser/#{id}/",
      headers: auth_headers
    )
    handle_response(response)
  end

  # Delete an agreement
  # @param id [String] Agreement UUID
  def delete_agreement(id:)
    response = self.class.delete(
      "#{BASE_URL}/agreements/enduser/#{id}/",
      headers: auth_headers
    )
    handle_response(response)
  end

  # ── requisitions ──────────────────────────────────────────────────

  # Create a requisition (initiates the bank authorization flow)
  # @param institution_id [String] Institution ID
  # @param redirect [String] Redirect URL after user authorizes
  # @param agreement [String, nil] EUA UUID (optional but recommended)
  # @param reference [String, nil] Custom reference for identifying the user
  # @param user_language [String, nil] Two-letter language code (ISO 639-1)
  # @param account_selection [Boolean] Enable account selection screen
  # @param redirect_immediate [Boolean] Redirect immediately after account list
  # @return [Hash] Created requisition with :link and :id
  def create_requisition(institution_id:, redirect:, agreement: nil, reference: nil,
                         user_language: nil, account_selection: false, redirect_immediate: false)
    body = {
      institution_id: institution_id,
      redirect: redirect,
      agreement: agreement,
      reference: reference,
      user_language: user_language,
      account_selection: account_selection,
      redirect_immediate: redirect_immediate
    }.compact
    response = self.class.post(
      "#{BASE_URL}/requisitions/",
      headers: auth_headers.merge("Content-Type" => "application/json"),
      body: body.to_json
    )
    handle_response(response)
  end

  # Get a requisition by ID
  # @param id [String] Requisition UUID
  # @return [Hash] Requisition details including :status and :accounts
  def get_requisition(id:)
    response = self.class.get(
      "#{BASE_URL}/requisitions/#{id}/",
      headers: auth_headers
    )
    handle_response(response)
  end

  # Delete a requisition
  # @param id [String] Requisition UUID
  def delete_requisition(id:)
    response = self.class.delete(
      "#{BASE_URL}/requisitions/#{id}/",
      headers: auth_headers
    )
    handle_response(response)
  end

  # ── accounts ──────────────────────────────────────────────────────

  # Get account details
  # @param id [String] Account UUID
  # @return [Hash] Account details
  def get_account(id:)
    response = self.class.get(
      "#{BASE_URL}/accounts/#{id}/",
      headers: auth_headers
    )
    handle_response(response)
  end

  # Get account details
  # @param id [String] Account UUID
  # @return [Hash] Account details (same as get_account, semantic alias)
  def get_account_details(id:)
    response = self.class.get(
      "#{BASE_URL}/accounts/#{id}/details/",
      headers: auth_headers
    )
    handle_response(response)
  end

  # Get account balances
  # @param id [String] Account UUID
  # @return [Hash] Balance information
  def get_account_balances(id:)
    response = self.class.get(
      "#{BASE_URL}/accounts/#{id}/balances/",
      headers: auth_headers
    )
    handle_response(response)
  end

  # Get account transactions
  # @param id [String] Account UUID
  # @param date_from [Date, String, nil] Start date for transactions
  # @param date_to [Date, String, nil] End date for transactions
  # @return [Hash] Transactions data with :transactions key
  #   The response contains :transactions => { :booked => [...], :pending => [...] }
  def get_account_transactions(id:, date_from: nil, date_to: nil)
    query = {}
    query[:date_from] = date_from.to_date.iso8601 if date_from
    query[:date_to] = date_to.to_date.iso8601 if date_to

    response = self.class.get(
      "#{BASE_URL}/accounts/#{id}/transactions/",
      headers: auth_headers,
      query: query.presence
    )
    handle_response(response)
  end

  private

  def ensure_valid_token
    if @access_token.blank?
      obtain_tokens
    elsif @access_token_expires_at && @access_token_expires_at <= Time.current + 60
      begin
        refresh_access_token
      rescue GocardlessError
        obtain_tokens
      end
    end
  end

  def auth_headers
    base_headers.merge(
      "Authorization" => "Bearer #{current_access_token}",
      "Accept" => "application/json"
    )
  end

  def base_headers
    { "Content-Type" => "application/json" }
  end

  def handle_response(response)
    case response.code
    when 200, 201
      parse_response_body(response)
    when 204
      {}
    when 400
      raise GocardlessError.new("Bad request to GoCardless API: #{response.body}", :bad_request)
    when 401
      raise GocardlessError.new("Invalid credentials or expired token", :unauthorized)
    when 403
      raise GocardlessError.new("Access forbidden - check your API permissions", :access_forbidden)
    when 404
      raise GocardlessError.new("Resource not found", :not_found)
    when 429
      raise GocardlessError.new("Rate limit exceeded. Please try again later.", :rate_limited)
    when 500..599
      raise GocardlessError.new("GoCardless server error (#{response.code}): #{response.body}", :server_error)
    else
      raise GocardlessError.new("Failed to fetch data: #{response.code} #{response.message} - #{response.body}", :fetch_failed)
    end
  rescue SocketError, Net::OpenTimeout, Net::ReadTimeout => e
    raise GocardlessError.new("Network error during request: #{e.message}", :request_failed)
  rescue => e
    raise unless e.is_a?(GocardlessError)
    raise
  end

  def parse_response_body(response)
    return {} if response.body.blank?
    JSON.parse(response.body, symbolize_names: true)
  rescue JSON::ParserError => e
    Rails.logger.error "GoCardless API: Failed to parse response: #{e.message}"
    raise GocardlessError.new("Failed to parse API response", :parse_error)
  end

  class GocardlessError < StandardError
    attr_reader :error_type

    def initialize(message, error_type = :unknown)
      super(message)
      @error_type = error_type
    end
  end
end
