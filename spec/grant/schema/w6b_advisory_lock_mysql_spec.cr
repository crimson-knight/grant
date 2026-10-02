require "../../support/m03_fixture"

# Advisory locks against a live server. The cases that hold on every adapter
# run on all three; the GET_LOCK / RELEASE_LOCK specifics run on MySQL.
describe "advisory locks, live (#{CURRENT_ADAPTER})" do
  it "names the MySQL lock after the key and hashes a key longer than 64 bytes" do
    Grant::AdvisoryLock.mysql_name("short").should eq "grant:short"
    long = "k" * 100
    name = Grant::AdvisoryLock.mysql_name(long)
    name.bytesize.should be <= 64
    name.should eq Grant::AdvisoryLock.mysql_name(long)
    name.should_not eq Grant::AdvisoryLock.mysql_name("j" * 100)
  end

  it "serializes two fibers on a key longer than the MySQL limit" do
    key = "w6b-long-" + "x" * 80
    events = [] of String
    done = Channel(Nil).new
    2.times do |index|
      spawn do
        Grant.with_advisory_lock(key, M03Fixture.adapter, 5.seconds) do
          events << "enter#{index}"
          sleep 40.milliseconds
          events << "leave#{index}"
        end
        done.send(nil)
      end
    end
    2.times { done.receive }
    events[0][5].should eq events[1][5]
    events[2][5].should eq events[3][5]
  end

  if CURRENT_ADAPTER == "mysql"
    it "holds GET_LOCK on the connection that runs the block and releases it afterwards" do
      adapter = M03Fixture.adapter
      name = Grant::AdvisoryLock.mysql_name("w6b-held")
      Grant.with_advisory_lock("w6b-held", adapter) do
        mine = adapter.open { |db| db.scalar("SELECT CONNECTION_ID()").as(Int).to_i64 }
        again = adapter.open { |db| db.scalar("SELECT CONNECTION_ID()").as(Int).to_i64 }
        again.should eq mine
        holder = adapter.open { |db| db.scalar("SELECT IS_USED_LOCK(?)", name).as(Int).to_i64 }
        holder.should eq mine
      end
      adapter.open { |db| db.scalar("SELECT IS_FREE_LOCK(?)", name).as(Int).to_i64 }.should eq 1
    end

    it "times out against a second MySQL session and succeeds once that session lets go" do
      key = "w6b-foreign"
      name = Grant::AdvisoryLock.mysql_name(key)
      foreign = DB.open(ADAPTER_URL)
      begin
        foreign.using_connection do |conn|
          conn.scalar("SELECT GET_LOCK(?, 0)", name).as(Int).to_i64.should eq 1
          error = expect_raises(Grant::AdvisoryLockTimeout) do
            Grant.with_advisory_lock(key, M03Fixture.adapter, 150.milliseconds) { }
          end
          error.key.should eq key
          conn.scalar("SELECT RELEASE_LOCK(?)", name).as(Int).to_i64.should eq 1
        end
      ensure
        foreign.close
      end
      reached = false
      Grant.with_advisory_lock(key, M03Fixture.adapter, 2.seconds) { reached = true }
      reached.should be_true
    end

    it "frees the lock when the holding session dies" do
      key = "w6b-death"
      name = Grant::AdvisoryLock.mysql_name(key)
      foreign = DB.open(ADAPTER_URL)
      begin
        foreign.using_connection do |conn|
          id = conn.scalar("SELECT CONNECTION_ID()").as(Int).to_i64
          conn.scalar("SELECT GET_LOCK(?, 0)", name)
          expect_raises(Grant::AdvisoryLockTimeout) do
            Grant.with_advisory_lock(key, M03Fixture.adapter, 100.milliseconds) { }
          end
          M03Fixture.adapter.open { |db| db.exec "KILL CONNECTION #{id}" }
        end
      rescue DB::Error
        # The killed session reports its own death; the freed lock is what matters.
      ensure
        foreign.close rescue nil
      end
      reached = false
      Grant.with_advisory_lock(key, M03Fixture.adapter, 3.seconds) { reached = true }
      reached.should be_true
    end

    it "gives the same session a re-entrant hold and releases it with the outermost block" do
      adapter = M03Fixture.adapter
      name = Grant::AdvisoryLock.mysql_name("w6b-reenter")
      Grant.with_advisory_lock("w6b-reenter", adapter) do
        Grant.with_advisory_lock("w6b-reenter", adapter, 200.milliseconds) { }
        # MySQL 5.7+ counts the nested GET_LOCK; the lock must still be held here.
        adapter.open { |db| db.scalar("SELECT IS_FREE_LOCK(?)", name).as(Int).to_i64 }.should eq 0
      end
      adapter.open { |db| db.scalar("SELECT IS_FREE_LOCK(?)", name).as(Int).to_i64 }.should eq 1
    end

    it "releases the lock when the block raises" do
      expect_raises(Exception, /inside w6b/) { Grant.with_advisory_lock("w6b-raise", M03Fixture.adapter) { raise "inside w6b" } }
      name = Grant::AdvisoryLock.mysql_name("w6b-raise")
      M03Fixture.adapter.open { |db| db.scalar("SELECT IS_FREE_LOCK(?)", name).as(Int).to_i64 }.should eq 1
    end
  end
end
