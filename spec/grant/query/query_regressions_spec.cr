require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class QueryRegressionParent < Grant::Base
    connection {{ adapter_literal }}
    table query_regression_parents

    column id : Int64, primary: true
    column name : String?
    timestamps

    has_many :students, class_name: QueryRegressionStudent

    validate :name, "Name cannot be blank" do |parent|
      !parent.name.to_s.blank?
    end
  end

  class QueryRegressionTeacher < Grant::Base
    connection {{ adapter_literal }}
    table query_regression_teachers

    column id : Int64, primary: true
    column name : String?

    has_many :klasses, class_name: QueryRegressionKlass
  end

  class QueryRegressionStudent < Grant::Base
    connection {{ adapter_literal }}
    table query_regression_students

    column id : Int64, primary: true
    column name : String?

    has_many :enrollments, class_name: QueryRegressionEnrollment, foreign_key: student_id
    has_many :klasses, class_name: QueryRegressionKlass, through: :enrollments
  end

  class QueryRegressionKlass < Grant::Base
    connection {{ adapter_literal }}
    table query_regression_klasses

    column id : Int64, primary: true
    column name : String?

    belongs_to teacher : QueryRegressionTeacher
    has_many :enrollments, class_name: QueryRegressionEnrollment, foreign_key: klass_id
    has_many :students, class_name: QueryRegressionStudent, through: :enrollments, source: :student
  end

  class QueryRegressionEnrollment < Grant::Base
    connection {{ adapter_literal }}
    table query_regression_enrollments

    column id : Int64, primary: true

    belongs_to student : QueryRegressionStudent, foreign_key: student_id : Int64?
    belongs_to klass : QueryRegressionKlass, foreign_key: klass_id : Int64?
  end

  class QueryRegressionCompany < Grant::Base
    connection {{ adapter_literal }}
    table query_regression_companies

    column id : Int32, primary: true
    column name : String?
  end

  class QueryRegressionItem < Grant::Base
    connection {{ adapter_literal }}
    table query_regression_items

    column item_id : String, primary: true, auto: false
    column item_name : String?

    before_create :generate_uuid

    def generate_uuid
      @item_id = UUID.random.to_s
    end
  end
{% end %}

describe "Luna query regressions Q-1 through Q-15" do
  before_all do
    QueryRegressionParent.migrator.drop_and_create
    QueryRegressionStudent.migrator.drop_and_create
    QueryRegressionTeacher.migrator.drop_and_create
    QueryRegressionKlass.migrator.drop_and_create
    QueryRegressionEnrollment.migrator.drop_and_create
    QueryRegressionCompany.migrator.drop_and_create
    QueryRegressionItem.migrator.drop_and_create
  end

  before_each do
    QueryRegressionEnrollment.clear
    QueryRegressionKlass.clear
    QueryRegressionStudent.clear
    QueryRegressionParent.clear
    QueryRegressionCompany.clear
    QueryRegressionItem.clear
  end

  it "Q-1 rejects injected structured field identifiers" do
    QueryRegressionParent.create!(name: "visible")
    QueryRegressionParent.create!(name: "hidden")

    expect_raises(ArgumentError) do
      QueryRegressionParent.where(name: "visible").where("id = -1 OR 1=1 OR id", :eq, -999_i64).select
    end
  end

  it "Q-2 keeps none empty for pluck and every bulk write form" do
    record = QueryRegressionParent.create!(name: "before")
    relation = QueryRegressionParent.none

    relation.pluck(:name).should be_empty
    relation.update_all(name: "after").should eq(0)
    relation.update_all({"name" => "after"}).should eq(0)
    relation.update_all({:name => "after"}).should eq(0)
    relation.update_all([{"name", "after"}] of Tuple(String, Grant::Columns::Type)).should eq(0)
    relation.update_all("name = 'after'").rows_affected.should eq(0)
    relation.delete_all.should eq(0)
    relation.touch_all(time: Time.utc(2020, 1, 1)).should eq(0)

    QueryRegressionParent.find!(record.id!).name.should eq("before")
  end

  it "Q-3 limits ordered bulk updates and deletes to the selected rows" do
    5.times { |index| QueryRegressionParent.create!(name: "before-#{index}") }

    affected = QueryRegressionParent.order(id: :asc).limit(2).update_all(name: "updated")
    affected.should eq(2)
    QueryRegressionParent.where(name: "updated").count.should eq(2)

    QueryRegressionParent.clear
    5.times { |index| QueryRegressionParent.create!(name: "delete-#{index}") }
    QueryRegressionParent.order(id: :desc).limit(2).delete_all.should eq(2)
    QueryRegressionParent.count.should eq(3)
  end

  it "Q-4 preserves nil members and handles empty IN and NOT IN lists" do
    QueryRegressionStudent.create!(name: "visible")
    QueryRegressionStudent.create!(name: nil)

    QueryRegressionStudent.where(name: ["visible", nil]).order(id: :asc).pluck(:name).should eq([["visible"], [nil]])
    QueryRegressionStudent.where(name: [] of String).select.should be_empty
    QueryRegressionStudent.where.not_in(:name, [] of String).count.should eq(2)
    QueryRegressionStudent.where.not_in(:name, ["visible", nil]).pluck(:name).should be_empty
  end

  it "Q-5 translates inequality with nil into IS NOT NULL" do
    QueryRegressionStudent.create!(name: "visible")
    null_student = QueryRegressionStudent.create!(name: nil)

    QueryRegressionStudent.where(:name, :neq, nil).pluck(:name).should eq([["visible"]])
    QueryRegressionStudent.first("WHERE name IS NULL").try(&.id!).should eq(null_student.id!)
  end

  it "Q-6 uses exclusive upper bounds in hash and where-chain ranges" do
    records = Array.new(3) { |index| QueryRegressionParent.create!(name: "parent-#{index}") }
    range = records.first.id!...records.last.id!

    QueryRegressionParent.where(id: range).order(id: :asc).pluck(:id).should eq([[records[0].id!], [records[1].id!]])
    QueryRegressionParent.where.between(:id, range).order(id: :asc).pluck(:id).should eq([[records[0].id!], [records[1].id!]])
    QueryRegressionParent.where(name: "parent-1").and(id: range).ids.should eq([records[1].id!])
  end

  it "Q-7 groups OR range bounds with AND" do
    records = ["inside", "inside", "inside", "inside", "outside"].map do |name|
      QueryRegressionParent.create!(name: name)
    end

    result = QueryRegressionParent.where(name: "outside")
      .or(id: records[1].id!...records[3].id!)
      .order(id: :asc)
      .pluck(:id)

    result.should eq([[records[1].id!], [records[2].id!], [records[4].id!]])
  end

  it "Q-8 expands raw bind arrays and checks placeholder counts" do
    records = Array.new(3) { |index| QueryRegressionParent.create!(name: "parent-#{index}") }
    lower_id = records.first.id!
    upper_id = records.last.id!

    QueryRegressionParent.where("id >= ? AND id <= ?", [lower_id, upper_id]).order(id: :asc).pluck(:id)
      .should eq(records.map { |record| [record.id!] })

    expect_raises(ArgumentError) do
      QueryRegressionParent.where("id = ?", [lower_id, upper_id]).select
    end
  end

  it "Q-9 documents a valid PostgreSQL numbered placeholder and runs that query" do
    documented_querying = File.read("docs/querying.md")
    documented_scopes = File.read("docs/core-features/querying-and-scopes.md")
    (documented_querying + documented_scopes).should contain("$1")
    (documented_querying + documented_scopes).should_not contain(" = $\"")

    QueryRegressionParent.create!(name: "bound")
    QueryRegressionParent.where("LOWER(name) = $1", "bound").pluck(:name).should eq([["bound"]])
  end

  it "Q-10 carries inner binds through IN, EXISTS, and NOT EXISTS subqueries" do
    matching = QueryRegressionParent.create!(name: "inner match")
    QueryRegressionParent.create!(name: "other")

    QueryRegressionParent.where(id: QueryRegressionParent.where(name: "inner match").select(:id)).ids.should eq([matching.id!])
    all_ids = [matching.id!, matching.id! + 1]
    QueryRegressionParent.order(id: :asc).where.exists(QueryRegressionParent.where(name: "inner match").select(:id)).ids.should eq(all_ids)
    QueryRegressionParent.order(id: :asc).where.not_exists(QueryRegressionParent.where(name: "missing").select(:id)).ids.should eq(all_ids)
  end

  it "Q-11 counts distinct rows through a subquery and honors projections" do
    QueryRegressionParent.create!(name: "same")
    QueryRegressionParent.create!(name: "same")
    QueryRegressionParent.create!(name: "other")

    QueryRegressionParent.distinct.count.should eq(3)
    QueryRegressionParent.distinct.select(:name).count.should eq(2)
  end

  it "Q-12 returns grouped counts keyed by their group values" do
    first_same = QueryRegressionParent.create!(name: "same")
    second_same = QueryRegressionParent.create!(name: "same")
    other = QueryRegressionParent.create!(name: "other")

    QueryRegressionParent.group_by(:name).count.should eq({"same" => 2_i64, "other" => 1_i64})

    expected_multi_group_counts = {} of Array(Grant::Columns::Type) => Int64
    expected_multi_group_counts[["same".as(Grant::Columns::Type), first_same.id!.as(Grant::Columns::Type)]] = 1_i64
    expected_multi_group_counts[["same".as(Grant::Columns::Type), second_same.id!.as(Grant::Columns::Type)]] = 1_i64
    expected_multi_group_counts[["other".as(Grant::Columns::Type), other.id!.as(Grant::Columns::Type)]] = 1_i64
    QueryRegressionParent.group_by([:name, :id]).count.should eq(expected_multi_group_counts)
  end

  it "Q-13 respects relation bounds and order while batching" do
    names = ["zulu", "alpha", "bravo", "charlie", "delta"]
    records = names.map { |name| QueryRegressionParent.create!(name: name) }

    limited_ids = [] of Int64
    QueryRegressionParent.order(id: :asc).limit(2).find_each(batch_size: 1) { |record| limited_ids << record.id! }
    limited_ids.should eq(records.first(2).map(&.id!))

    ordered_ids = [] of Int64
    QueryRegressionParent.order(name: :asc).find_each(batch_size: 2) { |record| ordered_ids << record.id! }
    ordered_ids.should eq([1, 2, 3, 4, 0].map { |index| records[index].id! })

    offset_ids = [] of Int64
    QueryRegressionParent.order(id: :asc).offset(1).find_each(batch_size: 2) { |record| offset_ids << record.id! }
    offset_ids.should eq(records.skip(1).map(&.id!).to_a)

    first_company = QueryRegressionCompany.create!(name: "one")
    second_company = QueryRegressionCompany.create!(name: "two")
    company_ids = [] of Int32
    QueryRegressionCompany.find_each(batch_size: 1) { |company| company_ids << company.id! }
    company_ids.should eq([first_company.id!, second_company.id!])

    first_item = QueryRegressionItem.create!(item_name: "one")
    second_item = QueryRegressionItem.create!(item_name: "two")
    item_ids = [] of String
    QueryRegressionItem.find_each(batch_size: 1) { |item| item_ids << item.item_id.not_nil! }
    item_ids.should eq([first_item.item_id.not_nil!, second_item.item_id.not_nil!].sort)
  end

  it "Q-14 qualifies plucked fields when joins contain the same column names" do
    parent = QueryRegressionParent.create!(name: "parent")
    QueryRegressionStudent.create!(name: "student")

    QueryRegressionParent.joins("query_regression_students", on: "query_regression_students.id = query_regression_students.id").pluck(:id).should eq([[parent.id!]])
  end

  it "Q-15 resolves both edges of a through association join" do
    student = QueryRegressionStudent.create!(name: "student")
    teacher = QueryRegressionTeacher.create!(name: "teacher")
    klass = QueryRegressionKlass.create!(name: "class", teacher_id: teacher.id)
    QueryRegressionEnrollment.create!(student_id: student.id, klass_id: klass.id)

    QueryRegressionStudent.joins(:klasses).order(id: :asc).pluck(:id).should eq([[student.id!]])
  end
end
