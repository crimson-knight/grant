require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class PpPost < Grant::Base
    connection {{ adapter_literal }}
    table pp_posts
    column id : Int64, primary: true
    column title : String
    has_many :pp_comments, as: :commentable, class_name: PpComment
    has_one :pp_cover, as: :imageable, class_name: PpCover
  end

  class PpPhoto < Grant::Base
    connection {{ adapter_literal }}
    table pp_photos
    column id : Int64, primary: true
    column caption : String
    has_many :pp_comments, as: :commentable, class_name: PpComment, dependent: :delete_all
    has_one :pp_cover, as: :imageable, class_name: PpCover, dependent: :nullify
  end

  class PpComment < Grant::Base
    connection {{ adapter_literal }}
    table pp_comments
    column id : Int64, primary: true
    column body : String
    belongs_to :commentable, polymorphic: true, optional: true
  end

  class PpCover < Grant::Base
    connection {{ adapter_literal }}
    table pp_covers
    column id : Int64, primary: true
    column url : String
    belongs_to :imageable, polymorphic: true, optional: true
  end

  class PpVehicle < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table pp_vehicles
    column id : Int64, primary: true
    column type : String
    column label : String
    has_many :pp_notes, as: :notable, class_name: PpNote
  end

  class PpCar < PpVehicle
  end

  class PpTruck < PpVehicle
  end

  class PpNote < Grant::Base
    connection {{ adapter_literal }}
    table pp_notes
    column id : Int64, primary: true
    column body : String
    belongs_to :notable, polymorphic: true, optional: true
  end

  class PpUuidDoc < Grant::Base
    connection {{ adapter_literal }}
    table pp_uuid_docs
    column id : UUID, primary: true, auto: false
    column title : String
    has_many :pp_uuid_notes, as: :subject, class_name: PpUuidNote
    has_one :pp_uuid_stamp, as: :subject, class_name: PpUuidStamp
  end

  class PpUuidNote < Grant::Base
    connection {{ adapter_literal }}
    table pp_uuid_notes
    column id : Int64, primary: true
    column body : String
    belongs_to :subject, polymorphic: true, foreign_key: subject_id : UUID?, optional: true
  end

  class PpUuidStamp < Grant::Base
    connection {{ adapter_literal }}
    table pp_uuid_stamps
    column id : Int64, primary: true
    column mark : String
    belongs_to :subject, polymorphic: true, foreign_key: subject_id : UUID?, optional: true
  end

  class PpSlugDoc < Grant::Base
    connection {{ adapter_literal }}
    table pp_slug_docs
    column id : String, primary: true, auto: false
    column title : String
    has_many :pp_slug_notes, as: :subject, class_name: PpSlugNote
  end

  class PpSlugNote < Grant::Base
    connection {{ adapter_literal }}
    table pp_slug_notes
    column id : Int64, primary: true
    column body : String
    belongs_to :subject, polymorphic: true, foreign_key: subject_id : String?, optional: true
  end

  # A String key column that points at targets with numeric, String and UUID keys.
  class PpAnyNote < Grant::Base
    connection {{ adapter_literal }}
    table pp_any_notes
    column id : Int64, primary: true
    column body : String
    belongs_to :subject, polymorphic: true, foreign_key: subject_id : String?, optional: true
  end
{% end %}

describe "polymorphic association preloading" do
  before_all do
    {% for model in [PpPost, PpPhoto, PpComment, PpCover, PpVehicle, PpNote, PpUuidDoc, PpUuidNote, PpUuidStamp, PpSlugDoc, PpSlugNote, PpAnyNote] %}
      {{ model }}.migrator.drop_and_create
    {% end %}
  end

  before_each do
    {% for model in [PpComment, PpCover, PpNote, PpUuidNote, PpUuidStamp, PpSlugNote, PpAnyNote, PpPost, PpPhoto, PpVehicle, PpUuidDoc, PpSlugDoc] %}
      {{ model }}.clear
    {% end %}
  end

  describe "has_many as:" do
    it "preloads only the comments stored for that owner class, though ids overlap" do
      post = PpPost.create!(title: "post")
      photo = PpPhoto.create!(caption: "photo")
      post.id.should eq(photo.id)
      PpComment.create!(body: "on post", commentable_id: post.id, commentable_type: "PpPost")
      PpComment.create!(body: "on photo", commentable_id: photo.id, commentable_type: "PpPhoto")
      PpComment.create!(body: "second on photo", commentable_id: photo.id, commentable_type: "PpPhoto")

      posts = PpPost.includes(:pp_comments).select
      posts.first.association_loaded?(:pp_comments).should be_true
      posts.first.pp_comments.map(&.body).should eq(["on post"])
      photos = PpPhoto.includes(:pp_comments).select
      photos.first.pp_comments.map(&.body).sort!.should eq(["on photo", "second on photo"])
      PpPost.find!(post.id).pp_comments.map(&.body).should eq(["on post"])
    end

    it "costs a constant number of queries for many owners" do
      6.times do |index|
        post = PpPost.create!(title: "post #{index}")
        PpComment.create!(body: "c#{index}", commentable_id: post.id, commentable_type: "PpPost")
      end

      AssociationQueryCounter.selects { PpPost.includes(:pp_comments).select.to_a }.should eq(2)
    end

    it "eager_loads through a join on the key and the stored type" do
      post = PpPost.create!(title: "post")
      photo = PpPhoto.create!(caption: "photo")
      PpComment.create!(body: "hit", commentable_id: post.id, commentable_type: "PpPost")
      PpComment.create!(body: "miss", commentable_id: post.id, commentable_type: "PpPost")
      PpComment.create!(body: "hit", commentable_id: photo.id, commentable_type: "PpPhoto")

      relation = PpPost.eager_load(:pp_comments)
      relation.to_sql.should contain("LEFT JOIN")
      relation.distinct?.should be_true

      posts = PpPost.eager_load(:pp_comments).where("pp_comments.body = ?", "hit").select
      posts.map(&.id).should eq([post.id])
      posts.first.pp_comments.map(&.body).should eq(["hit"])
    end

    it "counts and filters in SQL without loading rows" do
      post = PpPost.create!(title: "post")
      PpComment.create!(body: "a", commentable_id: post.id, commentable_type: "PpPost")
      PpComment.create!(body: "b", commentable_id: post.id, commentable_type: "PpPost")
      PpComment.create!(body: "other", commentable_id: post.id, commentable_type: "PpPhoto")

      post.pp_comments.count.should eq(2)
      post.pp_comments.where(body: "a").select.size.should eq(1)
      post.pp_comments.exists?.should be_true
      post.pp_comments.loaded?.should be_false
    end

    it "builds and creates rows with the type column filled in" do
      post = PpPost.create!(title: "post")
      comment = post.pp_comments.create!(body: "new")
      comment.commentable_type.should eq("PpPost")
      comment.commentable_id.should eq(post.id)
      post.pp_comments.count.should eq(1)
    end
  end

  describe "has_one as:" do
    it "preloads the single row for each owner" do
      post = PpPost.create!(title: "post")
      photo = PpPhoto.create!(caption: "photo")
      PpCover.create!(url: "post.png", imageable_id: post.id, imageable_type: "PpPost")
      PpCover.create!(url: "photo.png", imageable_id: photo.id, imageable_type: "PpPhoto")

      loaded = PpPost.includes(:pp_cover).select.first
      loaded.association_loaded?(:pp_cover).should be_true
      loaded.pp_cover.try(&.url).should eq("post.png")
      PpPhoto.includes(:pp_cover).select.first.pp_cover.try(&.url).should eq("photo.png")
    end

    it "has a setter that points the child at the owner and caches it" do
      post = PpPost.create!(title: "post")
      cover = PpCover.create!(url: "later.png")
      post.pp_cover = cover
      cover.imageable_type.should eq("PpPost")
      cover.imageable_id.should eq(post.id)
      post.association_loaded?(:pp_cover).should be_true
      post.pp_cover.should eq(cover)
      cover.save!
      PpPost.find!(post.id).pp_cover.try(&.id).should eq(cover.id)
    end

    it "caches the lazy result" do
      post = PpPost.create!(title: "post")
      PpCover.create!(url: "post.png", imageable_id: post.id, imageable_type: "PpPost")
      post.pp_cover
      AssociationQueryCounter.selects { post.pp_cover }.should eq(0)
    end
  end

  describe "belongs_to polymorphic" do
    it "preloads with one query per stored type" do
      post = PpPost.create!(title: "post")
      photo = PpPhoto.create!(caption: "photo")
      3.times { PpComment.create!(body: "p", commentable_id: post.id, commentable_type: "PpPost") }
      3.times { PpComment.create!(body: "f", commentable_id: photo.id, commentable_type: "PpPhoto") }

      comments = [] of PpComment
      queries = AssociationQueryCounter.selects { comments = PpComment.includes(:commentable).select.to_a }
      queries.should eq(3)
      comments.each do |comment|
        target = comment.commentable
        target.should_not be_nil
        target.class.name.should eq(comment.commentable_type)
      end
    end

    it "assigns through the setter and stores the polymorphic name" do
      photo = PpPhoto.create!(caption: "photo")
      comment = PpComment.new(body: "hello")
      comment.commentable = photo
      comment.commentable_type.should eq("PpPhoto")
      comment.commentable_id.should eq(photo.id)
      comment.save!
      PpComment.find!(comment.id).commentable.try(&.read_attribute("id")).should eq(photo.id)
    end
  end

  describe "STI base as polymorphic_name" do
    it "stores the STI root name and finds the record through it" do
      car = PpCar.create!(label: "car")
      truck = PpTruck.create!(label: "truck")
      PpCar.polymorphic_name.should eq("PpVehicle")
      PpVehicle.polymorphic_name.should eq("PpVehicle")

      note = PpNote.new(body: "car note")
      note.notable = car
      note.notable_type.should eq("PpVehicle")
      note.save!
      other = PpNote.new(body: "truck note")
      other.notable = truck
      other.save!

      PpCar.find!(car.id).pp_notes.map(&.body).should eq(["car note"])
      vehicles = PpVehicle.includes(:pp_notes).order(:id).select
      vehicles.map { |vehicle| vehicle.pp_notes.map(&.body) }.should eq([["car note"], ["truck note"]])

      notes = PpNote.includes(:notable).order(:id).select
      notes.first.notable.should be_a(PpCar)
      notes.last.notable.should be_a(PpTruck)
    end
  end

  describe "UUID keys" do
    it "stores, preloads, and reads back UUID-keyed targets" do
      doc = PpUuidDoc.create!(id: UUID.random, title: "uuid doc")
      other = PpUuidDoc.create!(id: UUID.random, title: "other doc")
      note = PpUuidNote.new(body: "n1")
      note.subject = doc
      note.subject_id.should eq(doc.id)
      note.subject_type.should eq("PpUuidDoc")
      note.save!
      PpUuidNote.create!(body: "n2", subject_id: doc.id, subject_type: "PpUuidDoc")
      PpUuidNote.create!(body: "n3", subject_id: other.id, subject_type: "PpUuidDoc")
      PpUuidStamp.create!(mark: "stamp", subject_id: doc.id, subject_type: "PpUuidDoc")

      docs = PpUuidDoc.includes(:pp_uuid_notes, :pp_uuid_stamp).order(:title).select
      docs.map(&.pp_uuid_notes.map(&.body).sort!).should eq([["n1", "n2"], ["n3"]].reverse)
      docs.find! { |item| item.id == doc.id }.pp_uuid_stamp.try(&.mark).should eq("stamp")

      notes = PpUuidNote.includes(:subject).order(:id).select
      notes.map { |item| item.subject.try(&.read_attribute("title")) }.should eq(["uuid doc", "uuid doc", "other doc"])
    end
  end

  describe "String keys" do
    it "stores, preloads, and reads back String-keyed targets" do
      doc = PpSlugDoc.create!(id: "intro", title: "Intro")
      PpSlugDoc.create!(id: "outro", title: "Outro")
      PpSlugNote.create!(body: "n1", subject_id: "intro", subject_type: "PpSlugDoc")
      note = PpSlugNote.new(body: "n2")
      note.subject = doc
      note.subject_id.should eq("intro")
      note.save!

      docs = PpSlugDoc.includes(:pp_slug_notes).order(:id).select
      docs.map(&.pp_slug_notes.size).should eq([2, 0])
      PpSlugNote.includes(:subject).select.each { |item| item.subject.try(&.read_attribute("id")).should eq("intro") }
    end

    it "lets one String key column point at numeric, String, and UUID targets" do
      post = PpPost.create!(title: "post")
      slug = PpSlugDoc.create!(id: "slug", title: "slug")
      uuid = PpUuidDoc.create!(id: UUID.random, title: "uuid")
      [post, slug, uuid].each do |target|
        note = PpAnyNote.new(body: "note")
        note.subject = target
        note.save!
      end

      notes = PpAnyNote.includes(:subject).order(:id).select
      notes.map { |item| item.subject.try(&.class.name) }.should eq(["PpPost", "PpSlugDoc", "PpUuidDoc"])
    end
  end

  describe "dependent options" do
    it "supports delete_all and nullify on the as: side" do
      photo = PpPhoto.create!(caption: "photo")
      PpComment.create!(body: "gone", commentable_id: photo.id, commentable_type: "PpPhoto")
      cover = PpCover.create!(url: "kept.png", imageable_id: photo.id, imageable_type: "PpPhoto")

      photo.destroy
      PpComment.count.should eq(0)
      reloaded = PpCover.find!(cover.id)
      reloaded.imageable_id.should be_nil
      reloaded.imageable_type.should be_nil
    end
  end
end
