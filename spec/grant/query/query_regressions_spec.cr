require "../../spec_helper"

describe "Luna query regressions Q-1 through Q-15" do
  before_all do
    Parent.migrator.drop_and_create
    Student.migrator.drop_and_create
    Teacher.migrator.drop_and_create
    Klass.migrator.drop_and_create
    Enrollment.migrator.drop_and_create
    Company.migrator.drop_and_create
    Item.migrator.drop_and_create
  end

  before_each do
    Enrollment.clear
    Klass.clear
    Student.clear
    Parent.clear
    Company.clear
    Item.clear
  end

  it "Q-1 rejects injected structured field identifiers" do
    Parent.create!(name: "visible")
    Parent.create!(name: "hidden")

    expect_raises(ArgumentError) do
      Parent.where(name: "visible").where("id = -1 OR 1=1 OR id", :eq, -999_i64).select
    end
  end

  it "Q-2 keeps none empty for pluck and every bulk write form" do
    record = Parent.create!(name: "before")
    relation = Parent.none

    relation.pluck(:name).should be_empty
    relation.update_all(name: "after").should eq(0)
    relation.update_all({"name" => "after"}).should eq(0)
    relation.update_all({:name => "after"}).should eq(0)
    relation.update_all([{"name", "after"}] of Tuple(String, Grant::Columns::Type)).should eq(0)
    relation.update_all("name = 'after'").rows_affected.should eq(0)
    relation.delete_all.should eq(0)
    relation.touch_all(time: Time.utc(2020, 1, 1)).should eq(0)

    Parent.find!(record.id!).name.should eq("before")
  end

  it "Q-3 limits ordered bulk updates and deletes to the selected rows" do
    5.times { |index| Parent.create!(name: "before-#{index}") }

    affected = Parent.order(id: :asc).limit(2).update_all(name: "updated")
    affected.should eq(2)
    Parent.where(name: "updated").count.should eq(2)

    Parent.clear
    5.times { |index| Parent.create!(name: "delete-#{index}") }
    Parent.order(id: :desc).limit(2).delete_all.should eq(2)
    Parent.count.should eq(3)
  end

  it "Q-4 preserves nil members and handles empty IN and NOT IN lists" do
    Student.create!(name: "visible")
    Student.create!(name: nil)

    Student.where(name: ["visible", nil]).order(id: :asc).pluck(:name).should eq([["visible"], [nil]])
    Student.where(name: [] of String).select.should be_empty
    Student.where.not_in(:name, [] of String).count.should eq(2)
    Student.where.not_in(:name, ["visible", nil]).pluck(:name).should be_empty
  end

  it "Q-5 translates inequality with nil into IS NOT NULL" do
    Student.create!(name: "visible")
    null_student = Student.create!(name: nil)

    Student.where(:name, :neq, nil).pluck(:name).should eq([["visible"]])
    Student.first("WHERE name IS NULL").try(&.id!).should eq(null_student.id!)
  end

  it "Q-6 uses exclusive upper bounds in hash and where-chain ranges" do
    records = 3.times.map { |index| Parent.create!(name: "parent-#{index}") }.to_a
    range = records.first.id!...records.last.id!

    Parent.where(id: range).order(id: :asc).pluck(:id).should eq([[records[0].id!], [records[1].id!]])
    Parent.where.between(:id, range).order(id: :asc).pluck(:id).should eq([[records[0].id!], [records[1].id!]])
    Parent.where(name: "parent-1").and(id: range).ids.should eq([records[1].id!])
  end

  it "Q-7 groups OR range bounds with AND" do
    records = ["inside", "inside", "inside", "inside", "outside"].map do |name|
      Parent.create!(name: name)
    end

    result = Parent.where(name: "outside")
      .or(id: records[1].id!...records[3].id!)
      .order(id: :asc)
      .pluck(:id)

    result.should eq([[records[1].id!], [records[2].id!], [records[4].id!]])
  end

  it "Q-8 expands raw bind arrays and checks placeholder counts" do
    records = 3.times.map { |index| Parent.create!(name: "parent-#{index}") }.to_a
    lower_id = records.first.id!
    upper_id = records.last.id!

    Parent.where("id >= ? AND id <= ?", [lower_id, upper_id]).order(id: :asc).pluck(:id)
      .should eq(records.map { |record| [record.id!] })

    expect_raises(ArgumentError) do
      Parent.where("id = ?", [lower_id, upper_id]).select
    end
  end

  it "Q-9 documents a valid PostgreSQL numbered placeholder and runs that query" do
    documented_querying = File.read("docs/querying.md")
    documented_scopes = File.read("docs/core-features/querying-and-scopes.md")
    (documented_querying + documented_scopes).should contain("$1")
    (documented_querying + documented_scopes).should_not contain(" = $\"")

    Parent.create!(name: "bound")
    Parent.where("LOWER(name) = $1", "bound").pluck(:name).should eq([["bound"]])
  end

  it "Q-10 carries inner binds through IN, EXISTS, and NOT EXISTS subqueries" do
    matching = Parent.create!(name: "inner match")
    Parent.create!(name: "other")

    Parent.where(id: Parent.where(name: "inner match").select(:id)).ids.should eq([matching.id!])
    all_ids = [matching.id!, matching.id! + 1]
    Parent.order(id: :asc).where.exists(Parent.where(name: "inner match").select(:id)).ids.should eq(all_ids)
    Parent.order(id: :asc).where.not_exists(Parent.where(name: "missing").select(:id)).ids.should eq(all_ids)
  end

  it "Q-11 counts distinct rows through a subquery and honors projections" do
    Parent.create!(name: "same")
    Parent.create!(name: "same")
    Parent.create!(name: "other")

    Parent.distinct.count.should eq(3)
    Parent.distinct.select(:name).count.should eq(2)
  end

  it "Q-12 returns grouped counts keyed by their group values" do
    first_same = Parent.create!(name: "same")
    second_same = Parent.create!(name: "same")
    other = Parent.create!(name: "other")

    Parent.group_by(:name).count.should eq({"same" => 2_i64, "other" => 1_i64})

    expected_multi_group_counts = {} of Array(Grant::Columns::Type) => Int64
    expected_multi_group_counts[["same".as(Grant::Columns::Type), first_same.id!.as(Grant::Columns::Type)]] = 1_i64
    expected_multi_group_counts[["same".as(Grant::Columns::Type), second_same.id!.as(Grant::Columns::Type)]] = 1_i64
    expected_multi_group_counts[["other".as(Grant::Columns::Type), other.id!.as(Grant::Columns::Type)]] = 1_i64
    Parent.group_by([:name, :id]).count.should eq(expected_multi_group_counts)
  end

  it "Q-13 respects relation bounds and order while batching" do
    names = ["zulu", "alpha", "bravo", "charlie", "delta"]
    records = names.map { |name| Parent.create!(name: name) }

    limited_ids = [] of Int64
    Parent.order(id: :asc).limit(2).find_each(batch_size: 1) { |record| limited_ids << record.id! }
    limited_ids.should eq(records.first(2).map(&.id!))

    ordered_ids = [] of Int64
    Parent.order(name: :asc).find_each(batch_size: 2) { |record| ordered_ids << record.id! }
    ordered_ids.should eq([1, 2, 3, 4, 0].map { |index| records[index].id! })

    offset_ids = [] of Int64
    Parent.order(id: :asc).offset(1).find_each(batch_size: 2) { |record| offset_ids << record.id! }
    offset_ids.should eq(records.skip(1).map(&.id!).to_a)

    first_company = Company.create!(name: "one")
    second_company = Company.create!(name: "two")
    company_ids = [] of Int32
    Company.find_each(batch_size: 1) { |company| company_ids << company.id! }
    company_ids.should eq([first_company.id!, second_company.id!])

    first_item = Item.create!(item_name: "one")
    second_item = Item.create!(item_name: "two")
    item_ids = [] of String
    Item.find_each(batch_size: 1) { |item| item_ids << item.item_id.not_nil! }
    item_ids.should eq([first_item.item_id.not_nil!, second_item.item_id.not_nil!].sort)
  end

  it "Q-14 qualifies plucked fields when joins contain the same column names" do
    parent = Parent.create!(name: "parent")
    Student.create!(name: "student")

    Parent.joins("students", on: "students.id = students.id").pluck(:id).should eq([[parent.id!]])
  end

  it "Q-15 resolves both edges of a through association join" do
    student = Student.create!(name: "student")
    teacher = Teacher.create!(name: "teacher")
    klass = Klass.create!(name: "class", teacher_id: teacher.id)
    Enrollment.create!(student_id: student.id, klass_id: klass.id)

    Student.joins(:klasses).order(id: :asc).pluck(:id).should eq([[student.id!]])
  end
end
