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

    if entry
      entry.account.sync_later
    elsif account_id
      # The representative entry was deleted after the job was queued. The
      # other entries on its account and date still need their sync, so fall
      # back to the account the job was scheduled for.
      Account.find_by(id: account_id)&.sync_later
    end
  end

  def self.schedule_for(entry)
    # Judge "future" in the family's time zone, not the app's: for a family
    # west of UTC the app can already be a day ahead, so Entry#scheduled?
    # (Date.current in the current zone) would call a tomorrow-for-the-family
    # entry "today" on paths that run in the app's zone (imports). Sync#perform
    # judges the date in this zone too.
    return unless entry.date > Time.current.in_time_zone(entry.account.family.resolved_time_zone).to_date

    # A few minutes past midnight on the entry's date, so Date.current has
    # definitively rolled over (avoids clock-skew edge cases) by run time.
    # Midnight in the family's zone, as Sync#perform judges the date there --
    # imports and bulk updates call this from jobs running in the app's zone.
    run_at = entry.date.in_time_zone(entry.account.family.resolved_time_zone) + 5.minutes
    set(wait_until: run_at).perform_later(entry.id, entry.account_id)
  end

  # Batch variant for paths that write many entries without going through
  # Entry#sync_account_later (imports, bulk updates). Enqueues one job per
  # (account, date) -- they'd all sync the same account on the same day.
  # The app-zone date filter is deliberately absent: schedule_for judges each
  # representative entry in its own family's time zone.
  def self.schedule_for_entries(entries)
    entries.select("DISTINCT ON (entries.account_id, entries.date) entries.*")
           .order("entries.account_id, entries.date")
           .each { |entry| schedule_for(entry) }
  end
end
