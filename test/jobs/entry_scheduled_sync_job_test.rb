require "test_helper"

class EntryScheduledSyncJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  test "schedule_for enqueues a job for the entry's date when scheduled" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)

    assert_enqueued_with(job: EntryScheduledSyncJob, args: [ entry.id, entry.account_id ]) do
      EntryScheduledSyncJob.schedule_for(entry)
    end
  end

  test "schedule_for runs just after midnight in the family's timezone" do
    families(:dylan_family).update!(timezone: "America/New_York")
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)
    expected_run_at = entry.date.in_time_zone("America/New_York") + 5.minutes

    assert_enqueued_with(job: EntryScheduledSyncJob, at: expected_run_at) do
      EntryScheduledSyncJob.schedule_for(entry)
    end
  end

  test "schedule_for enqueues a job when the entry is tomorrow in the family's zone but today in the app zone" do
    families(:dylan_family).update!(timezone: "America/Los_Angeles")

    # 04:00 UTC on 2026-11-11 is 20:00 PT on 2026-11-10: the entry is
    # dated app-today, so Date.current / Entry#scheduled? would skip it,
    # but it is still tomorrow for the family.
    travel_to Time.utc(2026, 11, 11, 4, 0, 0) do
      entry = create_transaction(account: accounts(:depository), date: Date.new(2026, 11, 11))
      expected_run_at = entry.date.in_time_zone("America/Los_Angeles") + 5.minutes

      assert_enqueued_with(job: EntryScheduledSyncJob, args: [ entry.id, entry.account_id ], at: expected_run_at) do
        EntryScheduledSyncJob.schedule_for(entry)
      end
    end
  end

  test "schedule_for does nothing for a non-scheduled entry" do
    entry = create_transaction(account: accounts(:depository), date: Date.current)

    assert_no_enqueued_jobs do
      EntryScheduledSyncJob.schedule_for(entry)
    end
  end

  test "schedule_for_entries enqueues one job per account and date, skipping non-scheduled entries" do
    account = accounts(:depository)
    date = 3.days.from_now.to_date
    first = create_transaction(account: account, date: date)
    second = create_transaction(account: account, date: date)
    later = create_transaction(account: account, date: date + 1.day)
    today = create_transaction(account: account, date: Date.current)

    assert_enqueued_jobs 2, only: EntryScheduledSyncJob do
      EntryScheduledSyncJob.schedule_for_entries(Entry.where(id: [ first.id, second.id, later.id, today.id ]))
    end
  end

  test "schedule_for_entries enqueues jobs for entries that are future in the family's zone only" do
    families(:dylan_family).update!(timezone: "America/Los_Angeles")

    travel_to Time.utc(2026, 11, 11, 4, 0, 0) do
      account = accounts(:depository)
      family_tomorrow = create_transaction(account: account, date: Date.new(2026, 11, 11))
      family_today = create_transaction(account: account, date: Date.new(2026, 11, 10))

      assert_enqueued_jobs 1, only: EntryScheduledSyncJob do
        EntryScheduledSyncJob.schedule_for_entries(Entry.where(id: [ family_tomorrow.id, family_today.id ]))
      end
    end
  end

  test "perform triggers a sync for the entry's account" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)

    Account.any_instance.expects(:sync_later).once

    EntryScheduledSyncJob.perform_now(entry.id)
  end

  test "perform syncs the account when the representative entry was deleted" do
    entry = create_transaction(account: accounts(:depository), date: 3.days.from_now.to_date)
    account = entry.account
    entry.destroy!

    Account.any_instance.expects(:sync_later).once

    EntryScheduledSyncJob.perform_now(entry.id, account.id)
  end

  test "perform is a no-op when the entry no longer exists" do
    assert_nothing_raised do
      EntryScheduledSyncJob.perform_now("nonexistent-id")
    end
  end

  test "perform is a no-op when both the entry and the account are gone" do
    assert_nothing_raised do
      EntryScheduledSyncJob.perform_now("nonexistent-id", "nonexistent-account")
    end
  end
end
