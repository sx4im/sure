class AddDeletedExternalIdsToEnableBankingAccounts < ActiveRecord::Migration[8.1]
  def change
    # External ids of provider entries the user deleted, keyed by the Sure
    # account they were deleted from: { "<account_id>" => ["enable_banking_...", ...] }.
    # The stored raw payload is never pruned, so the batch processor needs a
    # record of deletions to keep a deleted row from being re-imported on the
    # next sync. Keyed per account so unlinking and re-linking the same bank
    # account (which creates a new account id) does not inherit the old
    # account's deletions.
    add_column :enable_banking_accounts, :deleted_external_ids, :jsonb, default: {}, null: false
  end
end
