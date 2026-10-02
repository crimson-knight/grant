require "../../spec_helper"

describe "(callback feature)" do
  describe "#save (new record)" do
    it "runs before_save, before_create, after_create, after_save" do
      callback = Callback.new(name: "foo")
      callback.history = IO::Memory.new
      callback.save

      callback.history.to_s.strip.should eq <<-EOF
        before_validation
        after_validation
        before_save
        before_create
        after_create
        after_save
        after_create_commit
        after_save_commit
        after_commit
        EOF
    end
  end

  describe "#save" do
    it "runs before_save, before_update, after_update, after_save" do
      Callback.new(name: "foo").save
      callback = Callback.first!
      callback.history = IO::Memory.new
      callback.save

      callback.history.to_s.strip.should eq <<-EOF
        before_validation
        after_validation
        before_save
        before_update
        after_update
        after_save
        after_update_commit
        after_save_commit
        after_commit
        EOF
    end
  end

  describe "#destroy" do
    it "runs before_destroy, after_destroy" do
      Callback.new(name: "foo").save
      callback = Callback.first!
      callback.history = IO::Memory.new
      callback.destroy

      callback.history.to_s.strip.should eq <<-EOF
        before_destroy
        after_destroy
        after_destroy_commit
        after_commit
        EOF
    end
  end

  describe "an exception thrown in a hook" do
    it "should not get swallowed" do
      callback = Callback.new(name: "foo")
      # close IO in order to raise IO::Error in callback blocks
      callback.history.close

      expect_raises(IO::Error, "Closed stream") do
        callback.save
      end
    end
  end

  describe "manually triggered" do
    context "on a single model" do
      it "should successfully trigger the callback" do
        item = Item.new(item_name: "item1")
        item.item_id.should be_nil

        item.before_create

        item.item_id.should be_a(String)
      end
    end

    context "on an array of models" do
      it "should successfully trigger the callback" do
        items = [] of Item
        items << Item.new(item_name: "item1")
        items << Item.new(item_name: "item2")
        items << Item.new(item_name: "item3")
        items << Item.new(item_name: "item4")

        items.all? { |item| item.item_id.nil? }.should be_true

        items.each(&.before_create)

        items.all? { |item| item.item_id.is_a?(String) }.should be_true
      end
    end
  end
end
