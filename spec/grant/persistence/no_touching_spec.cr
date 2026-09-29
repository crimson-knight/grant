require "../../spec_helper"
require "../../support/write_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class QuietVehicle < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table quiet_vehicles

    column id : Int64, primary: true
    column type : String
    column name : String?
    timestamps
  end

  class QuietCar < QuietVehicle
  end

  class QuietNote < Grant::Base
    connection {{ adapter_literal }}
    table quiet_notes

    column id : Int64, primary: true
    column name : String?
    timestamps
  end
{% end %}

QuietVehicle.exec("DROP TABLE IF EXISTS quiet_vehicles")
case CURRENT_ADAPTER
when "pg"
  QuietVehicle.exec("CREATE TABLE quiet_vehicles (id BIGSERIAL PRIMARY KEY, type TEXT NOT NULL, name TEXT, created_at TIMESTAMP, updated_at TIMESTAMP)")
when "mysql"
  QuietVehicle.exec("CREATE TABLE quiet_vehicles (id BIGINT AUTO_INCREMENT PRIMARY KEY, type VARCHAR(255) NOT NULL, name VARCHAR(255), created_at TIMESTAMP NULL, updated_at TIMESTAMP NULL)")
else
  QuietVehicle.exec("CREATE TABLE quiet_vehicles (id INTEGER PRIMARY KEY AUTOINCREMENT, type VARCHAR(255) NOT NULL, name VARCHAR(255), created_at TEXT, updated_at TEXT)")
end
QuietNote.migrator.drop_and_create

STALE = Time.utc(2020, 1, 2, 3, 4, 5)

private def stored_stamp(note : QuietNote) : Time
  QuietNote.find!(note.id).updated_at.not_nil!.to_utc
end

describe "no_touching and suppress" do
  before_each do
    QuietNote.clear
    QuietVehicle.clear
  end

  describe ".no_touching" do
    it "turns touch into a no-op inside the block" do
      note = QuietNote.create!(name: "n")
      note.touch(time: STALE)

      statements = WriteSqlCapture.statements do
        QuietNote.no_touching { note.touch.should be_true }
      end
      statements.should be_empty
      stored_stamp(note).should eq(STALE)
    end

    it "touches again after the block" do
      note = QuietNote.create!(name: "n")
      note.touch(time: STALE)
      QuietNote.no_touching { note.touch }
      note.touch
      stored_stamp(note).should be > STALE
    end

    it "returns the block value and reports the state" do
      QuietNote.no_touching?.should be_false
      QuietNote.no_touching { QuietNote.no_touching?.should be_true; 42 }.should eq(42)
      QuietNote.no_touching?.should be_false
    end

    it "still stamps updated_at on a normal save" do
      note = QuietNote.create!(name: "n")
      note.touch(time: STALE)
      QuietNote.no_touching { note.update!(name: "changed") }
      stored_stamp(note).should be > STALE
    end

    it "only affects the named model" do
      note = QuietNote.create!(name: "n")
      vehicle = QuietVehicle.create!(name: "v", type: "QuietVehicle")
      vehicle.touch(time: STALE)
      QuietNote.no_touching { vehicle.touch }
      QuietVehicle.find!(vehicle.id).updated_at.not_nil!.to_utc.should be > STALE
    end

    it "covers subclasses when set on the parent" do
      car = QuietCar.create!(name: "c")
      car.touch(time: STALE)
      QuietVehicle.no_touching do
        car.no_touching?.should be_true
        car.touch
      end
      QuietVehicle.find!(car.id).updated_at.not_nil!.to_utc.should eq(STALE)
    end

    it "nests and unwinds even when the block raises" do
      QuietNote.no_touching do
        QuietNote.no_touching { }
        QuietNote.no_touching?.should be_true
      end
      QuietNote.no_touching?.should be_false

      expect_raises(Exception, "boom") { QuietNote.no_touching { raise "boom" } }
      QuietNote.no_touching?.should be_false
    end

    it "is fiber-local" do
      note = QuietNote.create!(name: "n")
      note.touch(time: STALE)
      other_fiber_sees = Channel(Bool).new

      QuietNote.no_touching do
        spawn { other_fiber_sees.send(QuietNote.no_touching?) }
        other_fiber_sees.receive.should be_false
        QuietNote.no_touching?.should be_true
      end

      done = Channel(Nil).new
      spawn do
        QuietNote.no_touching { Fiber.yield }
        done.send(nil)
      end
      Fiber.yield
      QuietNote.no_touching?.should be_false
      done.receive
    end
  end

  describe ".suppress" do
    it "turns save and create into successful no-ops inside the block" do
      statements = WriteSqlCapture.statements do
        QuietNote.suppress do
          record = QuietNote.create!(name: "ghost")
          record.new_record?.should be_true
          record.save.should be_true
          QuietNote.suppressed?.should be_true
        end
      end
      statements.should be_empty
      QuietNote.count.should eq(0)
      QuietNote.suppressed?.should be_false
    end

    it "does not write updates inside the block but does afterwards" do
      note = QuietNote.create!(name: "n")
      QuietNote.suppress { note.update!(name: "hidden") }
      QuietNote.find!(note.id).name.should eq("n")
      note.save!
      QuietNote.find!(note.id).name.should eq("hidden")
    end

    it "leaves other models alone" do
      QuietNote.suppress { QuietVehicle.create!(name: "v", type: "QuietVehicle") }
      QuietVehicle.count.should eq(1)
    end

    it "is fiber-local" do
      seen = Channel(Bool).new
      QuietNote.suppress do
        spawn { seen.send(QuietNote.suppressed?) }
        seen.receive.should be_false
      end
    end
  end
end
