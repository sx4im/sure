class AddDeletedExternalIdsToEnableBankingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_accounts, :deleted_external_ids, :jsonb, default: [], null: false
  end
end
