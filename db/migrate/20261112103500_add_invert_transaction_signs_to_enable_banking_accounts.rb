class AddInvertTransactionSignsToEnableBankingAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_accounts, :invert_transaction_signs, :boolean, default: false, null: false unless column_exists?(:enable_banking_accounts, :invert_transaction_signs)
  end
end
