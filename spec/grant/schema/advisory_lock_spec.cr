require "../../support/m03_fixture"
require "digest/md5"

private def m03_sqlite_lock_path(key : String) : String
  "#{M03Fixture.adapter.current_database}.grant-lock-#{Digest::MD5.hexdigest(key)[0, 12]}"
end

describe "advisory locks" do
  it "serializes two fibers that want the same key" do
    events = [] of String
    done = Channel(Nil).new
    2.times do |index|
      spawn do
        Grant.with_advisory_lock("m03-serial", M03Fixture.adapter, 5.seconds) do
          events << "enter#{index}"
          sleep 60.milliseconds
          events << "leave#{index}"
        end
        done.send(nil)
      end
    end
    2.times { done.receive }
    events.size.should eq 4
    # Each entry is followed at once by its own exit: the critical sections never overlap.
    events[0][5].should eq events[1][5]
    events[2][5].should eq events[3][5]
  end

  it "lets different keys run side by side" do
    inside = Channel(Nil).new
    release = Channel(Nil).new
    spawn do
      Grant.with_advisory_lock("m03-key-a", M03Fixture.adapter) do
        inside.send(nil)
        release.receive
      end
    end
    inside.receive
    reached = false
    Grant.with_advisory_lock("m03-key-b", M03Fixture.adapter, 1.second) { reached = true }
    reached.should be_true
    release.send(nil)
    sleep 10.milliseconds
  end

  it "times out while another holder keeps the key, then succeeds once it lets go" do
    inside = Channel(Nil).new
    release = Channel(Nil).new
    finished = Channel(Nil).new
    spawn do
      Grant.with_advisory_lock("m03-timeout", M03Fixture.adapter) do
        inside.send(nil)
        release.receive
      end
      finished.send(nil)
    end
    inside.receive
    error = expect_raises(Grant::AdvisoryLockTimeout) do
      Grant.with_advisory_lock("m03-timeout", M03Fixture.adapter, 100.milliseconds) { }
    end
    error.key.should eq "m03-timeout"
    release.send(nil)
    finished.receive
    Grant.with_advisory_lock("m03-timeout", M03Fixture.adapter, 1.second) { }
  end

  it "releases the lock when the block raises" do
    expect_raises(Exception, /inside the lock/) do
      Grant.with_advisory_lock("m03-raise", M03Fixture.adapter) { raise "inside the lock" }
    end
    Grant.with_advisory_lock("m03-raise", M03Fixture.adapter, 200.milliseconds) { }
  end

  it "lets the holder take the same key again" do
    value = Grant.with_advisory_lock("m03-reenter", M03Fixture.adapter, 200.milliseconds) do
      Grant.with_advisory_lock("m03-reenter", M03Fixture.adapter, 200.milliseconds) { 42 }
    end
    value.should eq 42
  end

  it "returns the block's value" do
    Grant.with_advisory_lock("m03-value", M03Fixture.adapter) { "done" }.should eq "done"
  end

  if CURRENT_ADAPTER == "pg"
    it "holds the lock on the connection that runs the block's statements" do
      adapter = M03Fixture.adapter
      Grant.with_advisory_lock("m03-connection", adapter) do
        pid = adapter.open { |db| db.scalar("SELECT pg_backend_pid()").as(Int).to_i64 }
        again = adapter.open { |db| db.scalar("SELECT pg_backend_pid()").as(Int).to_i64 }
        again.should eq pid
        held = adapter.open { |db| db.scalar("SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = #{pid}").as(Int).to_i64 }
        held.should eq 1
      end
      left = adapter.open { |db| db.scalar("SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND pid <> pg_backend_pid() AND granted").as(Int).to_i64 }
      left.should eq 0
    end

    it "serializes against a second PostgreSQL connection and releases when that connection dies" do
      key = "m03-death"
      foreign = DB.open(ADAPTER_URL)
      begin
        foreign.using_connection do |conn|
          pid = conn.scalar("SELECT pg_backend_pid()").as(Int).to_i64
          conn.scalar("SELECT pg_advisory_lock($1)", Grant::AdvisoryLock.key_to_int64(key))
          expect_raises(Grant::AdvisoryLockTimeout) do
            Grant.with_advisory_lock(key, M03Fixture.adapter, 150.milliseconds) { }
          end
          M03Fixture.adapter.open { |db| db.scalar("SELECT pg_terminate_backend(#{pid})") }
        end
      rescue DB::Error
        # The terminated connection reports its own death; the lock is what matters.
      ensure
        foreign.close rescue nil
      end
      reached = false
      Grant.with_advisory_lock(key, M03Fixture.adapter, 3.seconds) { reached = true }
      reached.should be_true
    end
  end

  if CURRENT_ADAPTER == "sqlite"
    it "waits on a file lock held by another process" do
      key = "m03-flock"
      Grant.with_advisory_lock(key, M03Fixture.adapter, 200.milliseconds) { }
      outside = File.open(m03_sqlite_lock_path(key), "a")
      outside.flock_exclusive
      begin
        expect_raises(Grant::AdvisoryLockTimeout) do
          Grant.with_advisory_lock(key, M03Fixture.adapter, 150.milliseconds) { }
        end
      ensure
        outside.flock_unlock
        outside.close
      end
      reached = false
      Grant.with_advisory_lock(key, M03Fixture.adapter, 1.second) { reached = true }
      reached.should be_true
    end
  end
end
