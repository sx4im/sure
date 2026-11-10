class EntryScheduledSyncJob < ApplicationJob
  # Scheduled (future-dated) entries are excluded from balance calculations
  # until their date arrives (see Entry#scheduled?, Balance::SyncCache). That
  # normally happens on the next sync -- but if host-wide auto-sync
  # (Setting.auto_sync_enabled) and the family's auto_sync_on_login are both
  # disabled, nothing would otherwise trigger a sync on that date. This job
  # is the fallback: it fires once, on the entry's date, and simply asks the
  # account to sync -- a cheap no-op if a sync already happened by then.
  def perform(entry_id, account_id = nil)
    entry = Entry.find_by(id: entry_id)

    # The enqueued entry is only the representative for its (account, date)
    # batch -- if it was deleted before the job runs, the other entries in
    # the batch still need their sync, so fall back to the account captured
    # at enqueue time. Jobs enqueued before account_id was added carry no
    # fallback and keep the old no-op behaviour.
    account = entry&.account || Account.find_by(id: account_id)
    account&.sync_later
  end

  def self.schedule_for(entry)
    family_zone = entry.account.family.resolved_time_zone

    # Judge "future" on the family's clock, not the app's: a family west of
    # UTC can still be on "yesterday" when the app (UTC) has already rolled
    # over, so Date.current / Entry#scheduled? would wrongly skip entries
    # dated app-today that are still tomorrow for the family. Web requests
    # run in the family's zone already, so this agrees with them there.
    return unless entry.date > Time.current.in_time_zone(family_zone).to_date

    # A few minutes past midnight on the entry's date, so Date.current has
    # definitively rolled over (avoids clock-skew edge cases) by run time.
    # Midnight in the family's zone, as Sync#perform judges the date there --
    # imports and bulk updates call this from jobs running in the app's zone.
    run_at = entry.date.in_time_zone(family_zone) + 5.minutes
    set(wait_until: run_at).perform_later(entry.id, entry.account_id)
  end

  # Batch variant for paths that write many entries without going through
  # Entry#sync_account_later (imports, bulk updates). Enqueues one job per
  # (account, date) -- they'd all sync the same account on the same day.
  def self.schedule_for_entries(entries)
    # Coarse pre-filter only: an entry dated before app-today can never be
    # future in any family zone (the furthest-west zone lags app-today by
    # under a day), so `>=` admits every possible candidate and schedule_for
    # then applies the precise per-family check above.
    entries.where("entries.date >= ?", Date.current)
           .select("DISTINCT ON (entries.account_id, entries.date) entries.*")
           .order("entries.account_id, entries.date")
           .each { |entry| schedule_for(entry) }
  end
end
