# frozen_string_literal: true
# Copyright (C) 2019 Twitter, Inc.

module TwitterAds

  # Generic container for API requests.
  class Request

    attr_reader :client, :method, :resource, :options

    HTTP_METHOD = {
      get:    Net::HTTP::Get,
      post:   Net::HTTP::Post,
      put:    Net::HTTP::Put,
      delete: Net::HTTP::Delete
    }.freeze

    DEFAULT_DOMAIN = 'https://ads-api.twitter.com'
    SANDBOX_DOMAIN = 'https://ads-api-sandbox.twitter.com'

    private_constant :DEFAULT_DOMAIN, :SANDBOX_DOMAIN, :HTTP_METHOD

    # Creates a new Request object instance.
    #
    # @example
    #   request = Request.new(client, :get, "/#{TwitterAds::API_VERSION}/accounts")
    #
    # @param client [Client] The Client object instance.
    # @param method [Symbol] The HTTP method to be used.
    # @param resource [String] The resource path for the request.
    #
    # @param opts [Hash] An optional Hash of extended options.
    # @option opts [String] :domain Forced override for default domain to use for the request. This
    #   value will also override :sandbox mode on the client.
    #
    # @since 0.1.0
    #
    # @return [Request] The Request object instance.
    def initialize(client, method, resource, opts = {})
      @client   = client
      @method   = method
      @resource = resource
      @options  = opts
      self
    end

    # Executes the current Request object.
    #
    # @example
    #   request = Request.new(client, :get, "/#{TwitterAds::API_VERSION}/accounts")
    #   request.perform
    #
    # @since  0.1.0
    #
    # @return [Response] The Response object instance generated by the Request.
    def perform
      handle_error(oauth_request)
    end

    private

    def domain
      @domain ||= begin
        @options[:domain] || (@client.options[:sandbox] ? SANDBOX_DOMAIN : DEFAULT_DOMAIN)
      end
    end

    def oauth_request
      request  = http_request
      consumer = OAuth::Consumer.new(@client.consumer_key, @client.consumer_secret, site: domain)
      token    = OAuth::AccessToken.new(consumer, @client.access_token, @client.access_token_secret)
      request.oauth!(consumer.http, consumer, token)

      handle_rate_limit = @client.options.fetch(:handle_rate_limit, false)
      retry_max         = @client.options.fetch(:retry_max, 0)
      retry_delay       = @client.options.fetch(:retry_delay, 1500)
      retry_on_status   = @client.options.fetch(:retry_on_status, [500, 503])
      retry_count       = 0
      retry_after       = nil

      write_log(request) if @client.options[:trace]
      while retry_count <= retry_max
        response = consumer.http.request(request)
        status_code = response.code.to_i
        break if status_code >= 200 && status_code < 300

        if handle_rate_limit && retry_after.nil?
          rate_limit_reset = response.fetch('x-account-rate-limit-reset', nil) ||
                             response.fetch('x-rate-limit-reset', nil)
          if status_code == 429
            retry_after = rate_limit_reset.to_i - Time.now.to_i
            @client.logger.warn('Request reached Rate Limit: resume in %d seconds' % retry_after)
            sleep(retry_after + 5)
            next
          end
        end

        if retry_max.positive?
          break unless retry_on_status.include?(status_code)
          sleep(retry_delay / 1000)
        end

        retry_count += 1
      end
      write_log(response) if @client.options[:trace]

      Response.new(response.code, response.each {}, response.body)
    end

    def http_request
      request_url = @resource

      if @options[:params] && !@options[:params].empty?
        request_url += "?#{URI.encode_www_form(@options[:params])}"
      end

      request      = HTTP_METHOD[@method].new(request_url)
      request.body = @options[:body] if @options[:body]

      @options[:headers]&.each { |header, value| request[header] = value }
      request['user-agent'] = user_agent

      request
    end

    def user_agent
      "twitter-ads version: #{TwitterAds::VERSION} " \
      "platform: #{RUBY_ENGINE} #{RUBY_VERSION} (#{RUBY_PLATFORM})"
    end

    def write_log(object)
      if object.respond_to?(:code)
        @client.logger.info("Status: #{object.code} #{object.message}")
      else
        @client.logger.info("Send: #{object.method} #{domain}#{@resource} #{@options[:params]}")
      end

      object.each { |header| @client.logger.info("Header: #{header}: #{object[header]}") }

      # suppresses body content for non-Ads API domains (eg. upload.twitter.com)
      unless object.body&.empty?
        if @domain == SANDBOX_DOMAIN || @domain == DEFAULT_DOMAIN
          @client.logger.info("Body: #{object.body}")
        else
          @client.logger.info('Body: **OMITTED**')
        end
      end
    end

    def handle_error(response)
      raise TwitterAds::Error.from_response(response) unless response.code < 400
      response
    end

  end

end
