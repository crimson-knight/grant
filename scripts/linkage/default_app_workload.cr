# The workload of `default_app_probe.cr` and `grant_engine_app_probe.cr`:
# what a default Amber app does with Grant on SQLite, after the adapter is
# required by the probe.
Grant::Connections << Grant::Adapter::Sqlite.new(name: "primary", url: "sqlite3::memory:")
Grant::Logs.verbose_query_logs = true

class Author < Grant::Base
  connection primary
  table authors

  column id : Int64, primary: true
  column full_name : String
  column contact_email : String?
  column homepage_url : String?
  timestamps

  has_many :articles, class_name: Article, foreign_key: :author_id

  normalizes :full_name, &.strip
  validates_presence_of :full_name
  validates_length_of :full_name, maximum: 80
  validates_email :contact_email, allow_nil: true
  validates_url :homepage_url, allow_nil: true
  filter_attributes :contact_email
end

class Article < Grant::Base
  connection primary
  table articles

  column id : Int64, primary: true
  column title : String
  column word_count : Int32 = 0
  column author_id : Int64?

  belongs_to :author, class_name: Author, foreign_key: :author_id

  scope :long_reads, ->(query : Grant::Query::Builder(Article)) { query.where(:word_count, :gteq, 1000) }
end

Author.migrator.drop_and_create
Article.migrator.drop_and_create

author = Author.new(full_name: "  Ada Lovelace ", contact_email: "ada@example.com", homepage_url: "https://example.com/ada")
author.save!
Author.transaction do
  Article.create!(title: "Notes", word_count: 1200, author_id: author.id)
  Article.create!(title: "Letters", word_count: 300, author_id: author.id)
end

puts Article.where(title: "Notes").order("title DESC, id").limit(5).map(&.title).join(", ")
puts Article.joins(:author).where("authors.full_name": "Ada Lovelace").count
puts Article.includes(:author).order(word_count: :desc).first.try(&.author).try(&.full_name)
puts Article.long_reads.pluck(:title).inspect
puts Article.all("WHERE word_count > ? ORDER BY id DESC LIMIT 1", [100] of Grant::Columns::Type).map(&.title).inspect
puts Article.order("lower(title) asc").reverse_order.first.try(&.title)
puts author.articles.count
puts Article.sum(:word_count)
puts Article.all.sum("word_count * 1.5")
puts Article.all.sum(:word_count, as: Int64)
puts Article.where(id: Article.all.ids.map(&.as(Int64))).in_chunks(of: 1).sum(:word_count)
puts Article.avg(:word_count)
puts Author.find_by(full_name: "Ada Lovelace").inspect

invalid = Author.new(full_name: "", contact_email: "not-an-email", homepage_url: "ftp://example.com")
puts invalid.valid?
puts invalid.errors.map(&.full_message).join("; ")
puts "sqlite_engine: #{Grant.settings.sqlite_engine}"
