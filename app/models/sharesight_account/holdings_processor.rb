class SharesightAccount::HoldingsProcessor
  include SharesightAccount::DataHelpers

  def initialize(sharesight_account)
    @sharesight_account = sharesight_account
  end

  def process
    return unless account.present?

    holdings = Array(@sharesight_account.raw_holdings_payload)
    holdings.each do |holding|
      process_holding(holding)
    end
    zero_out_sold_holdings(holdings)
  end

  private

    def account
      @sharesight_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def portfolio_currency
      @sharesight_account.currency
    end

    def process_holding(holding)
      instrument = holding["instrument"] || {}
      quantity = parse_decimal(holding["quantity"])
      # Sold holdings come back with no units, and "limited" ones (hidden on
      # cheaper plans) have no numbers at all.
      return unless quantity&.positive?
      return if holding["limited"]

      security = resolve_security(instrument["code"], instrument["market_code"], instrument["name"])
      return unless security

      currency, price = holding_price(holding, quantity)
      return unless price

      date = Date.current

      import_adapter.import_holding(
        security: security,
        quantity: quantity,
        amount: quantity * price,
        currency: currency,
        date: date,
        price: price,
        external_id: "sharesight_holding_#{@sharesight_account.sharesight_account_id}_#{holding['id']}_#{date}",
        source: "sharesight",
        account_provider_id: @sharesight_account.account_provider&.id,
        delete_future_holdings: false
      )
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "SharesightAccount::HoldingsProcessor - Failed to process holding #{holding['id']}: #{e.message}",
        source: "sharesight",
        family: @sharesight_account.sharesight_item.family,
        provider_key: "sharesight",
        metadata: { holding_id: holding["id"], sharesight_account_id: @sharesight_account.id }
      )
    end

    # A holding Sharesight reports with zero units was sold, but nothing
    # removes the row Sure already has for it: current_holdings reads the
    # latest snapshot date, so the sold units keep showing until another
    # day's snapshot leaves them out. Write a zero-quantity row for today,
    # which current_holdings already filters out, so the sale takes effect
    # the day it happened — including a sale between two syncs on the same
    # day, where today's row is updated in place (the external id carries
    # the date). Limited holdings have no numbers at all, so a nil
    # quantity is not a sale.
    def zero_out_sold_holdings(holdings)
      holdings.each do |holding|
        begin
          next if holding["limited"]
          next unless parse_decimal(holding["quantity"])&.zero?

          instrument = holding["instrument"] || {}
          security = resolve_security(instrument["code"], instrument["market_code"], instrument["name"])
          next unless security

          date = Date.current
          import_adapter.import_holding(
            security: security,
            quantity: BigDecimal("0"),
            amount: BigDecimal("0"),
            currency: @sharesight_account.holding_currencies[holding["id"].to_s] || portfolio_currency,
            date: date,
            price: parse_decimal(holding["instrument_price"]) || BigDecimal("0"),
            external_id: "sharesight_holding_#{@sharesight_account.sharesight_account_id}_#{holding['id']}_#{date}",
            source: "sharesight",
            account_provider_id: @sharesight_account.account_provider&.id,
            delete_future_holdings: false
          )
        rescue => e
          DebugLogEntry.capture(
            category: "sync",
            level: "error",
            message: "SharesightAccount::HoldingsProcessor - Failed to zero out sold holding #{holding['id']}: #{e.message}",
            source: "sharesight",
            family: @sharesight_account.sharesight_item.family,
            provider_key: "sharesight",
            metadata: { holding_id: holding["id"], sharesight_account_id: @sharesight_account.id }
          )
        end
      end
    end

    # Use the instrument's own price and currency when we have both, otherwise
    # the holding's value per unit in the portfolio's currency.
    def holding_price(holding, quantity)
      price = parse_decimal(holding["instrument_price"])
      currency = @sharesight_account.holding_currencies[holding["id"].to_s]
      return [ currency, price ] if currency && price

      value = parse_decimal(holding["value"])
      return [ portfolio_currency, value / quantity ] if value

      [ portfolio_currency, price ]
    end
end
