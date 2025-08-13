# CRUD

## Create

Combination of object creation and insertion into database.

```crystal
Post.create(name: "Grant Rocks!", body: "Check this out.") # Set attributes and call save
Post.create!(name: "Grant Rocks!", body: "Check this out.") # Set attributes and call save!. Will throw an exception when the save failed
```

To create a record without setting the `created_at` & `updated_at` fields, you can pass in `skip_timestamps`.

```crystal
Post.create({name: "Grant Rocks!", body: "Check this out."}, skip_timestamps: true)
```

## Insert

Inserts an already created object into the database.

```crystal
post = Post.new
post.name = "Grant Rocks!"
post.body = "Check this out."
post.save

post = Post.new
post.name = "Grant Rocks!"
post.body = "Check this out."
post.save! # raises when save failed
```

To skip the validation callbacks, pass in `validate: false`:

```crystal
post.save(validate: false)
post.save!(validate: false)
```

You can also pass in `skip_timestamps` to save without changing the `updated_at` field on update:

```crystal
post.save(skip_timestamps: true)
post.save!(skip_timestamps: true)
```

## Read

### find

Finds the record with the given primary key.

```crystal
post = Post.find 1
if post
  puts post.name
end

post = Post.find! 1 # raises when no records found
```

### find_by

Finds the record(s) that match the given criteria

```crystal
post = Post.find_by(slug: "example_slug")
if post
  puts post.name
end

post = Post.find_by!(slug: "foo") # raises when no records found.
other_post = Post.find_by(slug: "foo", type: "bar") # Also works for multiple arguments.
```

### first

Returns the first record.

```crystal
post = Post.first
if post
  puts post.name
end

post = Post.first! # raises when no records exist
```

### reload

Returns the record with the attributes reloaded from the database.

**Note:** this method is only defined when the `Spec` module is present.

```
post = Post.create(name: "Grant Rocks!", body: "Check this out.")
# record gets updated by another process
post.reload # performs another find to fetch the record again
```

### where, order, limit, offset, group_by

See [querying](./querying.md) for more details of using the QueryBuilder.

### all

Returns all records of a model.

```crystal
posts = Post.all
if posts
  posts.each do |post|
    puts post.name
  end
end
```

See [querying](./querying.md#all) for more details on using `all`

## Update

Updates a given record already saved in the database.

```crystal
post = Post.find 1
post.name = "Grant Really Rocks!"
post.save

post = Post.find 1
post.update(name: "Grant Really Rocks!") # Assigns attributes and calls save

post = Post.find 1
post.update!(name: "Grant Really Rocks!") # Assigns attributes and calls save!. Will throw an exception when the save failed
```

To update a record without changing the `updated_at` field, you can pass in `skip_timestamps`:

```crystal
post = Post.find 1
post.update({name: "Grant Really Rocks!"}, skip_timestamps: true)
post.update!({name: "Grant Really Rocks!"}, skip_timestamps: true)
```

## Delete

Delete a specific record.

```crystal
post = Post.find 1
post.destroy if post
puts "deleted" if post.destroyed?

post = Post.find 1
post.destroy! # raises when delete failed
```

Clear all records of a model

```crystal
Post.clear #truncate the table
```
