class SharesightAccount::HoldingsProcessor
  include SharesightAccount::DataHelpers

  def initialize(sharesight_account)
    @sharesight_account = sharesight_account
  end

  def process
    return unless account.present?

    Array(@sharesight_account.raw_holdings_payload).each do |holding|
      process_holding(holding)
    end
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
      # "Limited" holdings (hidden on cheaper plans) have no numbers at all,
      # so there is nothing to tell one from a sold position.
      return if holding["limited"]
      return unless quantity

      security = resolve_security(instrument["code"], instrument["market_code"], instrument["name"])
      return unless security

      # A holding Sharesight reports with no units was sold. Nothing is
      # imported for it, so its latest row keeps showing in current holdings
      # until a newer snapshot arrives; zero that row instead.
      return zero_sold_holding(security) if quantity.zero?
      return unless quantity.positive?

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

    # Zeroes the latest provider row for a sold security in place. Writing a
    # new row would move the snapshot forward, but the row's date is the
    # snapshot it was, and current_holdings already leaves zero quantities
    # out, so the position disappears without rewriting its history.
    def zero_sold_holding(security)
      provider_id = @sharesight_account.account_provider&.id
      return unless provider_id

      holding = account.holdings
        .where(account_provider_id: provider_id)
        .where("provider_security_id = :id OR (provider_security_id IS NULL AND security_id = :id)", id: security.id)
        .order(date: :desc)
        .first
      holding&.update!(qty: 0, amount: 0)
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
