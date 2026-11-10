require "test_helper"

class SharesightItemTest < ActiveSupport::TestCase
  test "schedule_account_syncs also syncs the manual settlement and dividend accounts" do
    family = families(:dylan_family)
    item = family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    portfolio = family.accounts.create!(name: "Shares", balance: 0, currency: "AUD", accountable: Investment.new)
    settlement = family.accounts.create!(name: "Macquarie CMA", balance: 0, currency: "AUD", accountable: Depository.new)
    dividends = family.accounts.create!(name: "CommBank", balance: 0, currency: "AUD", accountable: Depository.new)
    sharesight_account = item.sharesight_accounts.create!(
      name: "Shares", currency: "AUD", sharesight_account_id: "42",
      cash_mode: "settlement", settlement_account: settlement,
      dividend_mode: "other_account", dividend_account: dividends
    )
    sharesight_account.ensure_account_provider!(portfolio)

    results = item.schedule_account_syncs

    assert_equal [ portfolio.id, settlement.id, dividends.id ].sort,
                 results.filter_map { |result| result[:account_id] if result[:success] }.sort
    assert settlement.syncs.visible.any?
    assert dividends.syncs.visible.any?
  end

  test "schedule_account_syncs leaves the settlement account alone while the broker holds the cash" do
    family = families(:dylan_family)
    item = family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    portfolio = family.accounts.create!(name: "Shares", balance: 0, currency: "AUD", accountable: Investment.new)
    settlement = family.accounts.create!(name: "Macquarie CMA", balance: 0, currency: "AUD", accountable: Depository.new)
    sharesight_account = item.sharesight_accounts.create!(
      name: "Shares", currency: "AUD", sharesight_account_id: "42",
      cash_mode: "broker", settlement_account: settlement
    )
    sharesight_account.ensure_account_provider!(portfolio)

    results = item.schedule_account_syncs

    assert_equal [ portfolio.id ], results.filter_map { |result| result[:account_id] if result[:success] }
    assert_empty settlement.syncs.visible
  end

  test "accounts uses portfolios that are already loaded" do
    family = families(:dylan_family)
    item = family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    2.times do |i|
      account = family.accounts.create!(name: "Shares #{i}", balance: 0, currency: "AUD", accountable: Investment.new)
      item.sharesight_accounts.create!(name: "Shares #{i}", currency: "AUD", sharesight_account_id: i.to_s).ensure_account_provider!(account)
    end

    loaded = SharesightItem.includes(sharesight_accounts: [ :account, :linked_account ]).find(item.id)

    assert_queries_count(0) { assert_equal 2, loaded.accounts.size }
  end
end
