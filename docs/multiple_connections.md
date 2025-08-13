# Read replica support

In Grant, you can create a connection that has a write/read node. If this is done. Grant will perform write operations on the primary node and read operations on the secondary node. Here is an example:

```crystal
Grant::Connections << {name: "psql", writer: "...", reader: "...", adapter_type: Grant::Adapter::Pg}
```

The first parameter `name` is the name of the connection. When you create a model in Grant, you can specify a connection via the `connection` macro. If I wanted to use the above connection in a model. I would write

```crystal
class User < Grant::Base
  connection "psql"
end
```

where the value provided to the `connection` macro is the name of the grant connection you want to use.

The `writer` is a connection string to the database node that has read/write access.

The `reader` is a connection string to the database node that can only be read from.

The final argument is a subclass of `Grant::Adapter::Base`. You're basically telling grant what kind of database adapter to use for this connection. Grant comes with adapters for Postgres, MySQL, and SQLite.

## configuring the connection switch wait period

By default, when you perform a write operation on a Grant model, all read requests switch to using the primary database node. This is to allow the changes done to propogate to the read replicas before using them again. 

The default value is `2000` milliseconds. You can change this value like this

```crystal
Grant::Conections.connection_switch_wait_period = 2000 #=> time in milliseconds
```
