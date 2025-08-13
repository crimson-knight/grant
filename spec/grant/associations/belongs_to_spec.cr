require "../../spec_helper"

describe "belongs_to" do
  it "provides a getter for the foreign entity" do
    teacher = Teacher.new
    teacher.name = "Test teacher"
    teacher.save

    klass = Klass.new
    klass.name = "Test klass"
    klass.teacher_id = teacher.id
    klass.save

    klass.teacher.not_nil!.id.should eq teacher.id
  end

  it "provides a setter for the foreign entity" do
    teacher = Teacher.new
    teacher.name = "Test teacher"
    teacher.save

    klass = Klass.new
    klass.name = "Test klass"
    klass.teacher = teacher
    klass.save

    klass.teacher_id.should eq teacher.id
  end

  it "supports custom types for the join" do
    book = Book.new
    book.name = "Screw driver"
    book.save

    review = BookReview.new
    review.book = book
    review.body = "Best book ever!"
    review.save

    review.book.not_nil!.name.should eq "Screw driver"
  end

  it "supports custom method name" do
    author = Person.new
    author.name = "John Titor"
    author.save

    book = Book.new
    book.name = "How to Time Traveling"
    book.author = author
    book.save

    book.author.not_nil!.name.should eq "John Titor"
  end

  it "supports both custom method name and custom types for the join" do
    publisher = Company.new
    publisher.name = "Amber Framework"
    publisher.save

    book = Book.new
    book.name = "Introduction to Grant"
    book.publisher = publisher
    book.save

    book.publisher.not_nil!.name.should eq "Amber Framework"
  end

  it "supports json_options" do
    publisher = Company.new
    publisher.name = "Amber Framework"
    publisher.save

    book = Book.new
    book.name = "Introduction to Grant"
    book.publisher = publisher
    book.save
    book.to_json.should eq %({"id":#{book.id},"name":"Introduction to Grant"})
  end

  it "supports yaml_options" do
    publisher = Company.new
    publisher.name = "Amber Framework"
    publisher.save

    book = Book.new
    book.name = "Introduction to Grant"
    book.publisher = publisher
    book.save
    book.to_yaml.should eq %(---\nid: #{book.id}\nname: Introduction to Grant\n)
  end

  it "provides a method to retrieve parent object that will raise if record is not found" do
    book = Book.new
    book.name = "Introduction to Grant"

    expect_raises Grant::Querying::NotFound, "No Company found where id is NULL" { book.publisher! }
  end

  it "provides the ability to use a custom primary key" do
    courier = Courier.new
    courier.courier_id = 139_132_751
    courier.issuer_id = 999

    service = CourierService.new
    service.owner_id = 123_321
    service.name = "My Service"
    service.save

    courier.service = service
    courier.save

    courier.service!.owner_id.should eq 123_321
  end

  it "allows a belongs_to association to be a primary key" do
    chat = Chat.new
    chat.name = "My Awesome Chat"
    chat.save

    settings = ChatSettings.new
    settings.chat = chat
    settings.save

    settings.chat_id!.should eq chat.id
  end

  it "provides the ability to define a converter for the foreign key" do
    uuid_model = UUIDModel.new
    uuid_model.save

    uuid_relation = UUIDRelation.new
    uuid_relation.uuid_model = uuid_model
    uuid_relation.save

    uuid_relation.uuid_model_id.should eq uuid_model.uuid
  end
end
