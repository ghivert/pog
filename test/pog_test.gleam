import exception
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/charlist.{type Charlist}
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/time/calendar
import gleam/time/timestamp
import gleeunit
import pog

pub fn main() {
  gleeunit.main()
}

fn disconnect(db: actor.Started(a)) -> Nil {
  process.send_exit(db.pid)
}

fn start_default() -> actor.Started(pog.Connection) {
  let assert Ok(started) =
    process.new_name("pog_test")
    |> default_config
    |> pog.start
  started
}

/// Connection settings are read from the same environment variables as
/// `psql` and `test/reset_db.sh`, falling back to a local Postgres.
fn default_config(name) {
  let assert Ok(port) = int.parse(env("PGPORT", "5432"))
  pog.Config(
    ..pog.default_config(name),
    host: env("PGHOST", "127.0.0.1"),
    port:,
    user: env("PGUSER", "postgres"),
    password: Some(env("PGPASSWORD", "postgres")),
    database: "gleam_pog_test",
    pool_size: 1,
  )
}

fn env(name: String, default: String) -> String {
  getenv(charlist.from_string(name), charlist.from_string(default))
  |> charlist.to_string
}

@external(erlang, "os", "getenv")
fn getenv(name: Charlist, default: Charlist) -> Charlist

pub fn url_config_everything_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(1234)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(Some("p"))

  assert pog.url_config(name, "postgres://u:p@db.test:1234/my_db")
    == Ok(expected)
}

pub fn url_config_alternative_postgres_protocol_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(1234)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(Some("p"))
  assert pog.url_config(name, "postgresql://u:p@db.test:1234/my_db")
    == Ok(expected)
}

pub fn url_config_not_postgres_protocol_test() {
  let name = process.new_name("pog_test")
  assert pog.url_config(name, "foo://u:p@db.test:1234/my_db") == Error(Nil)
}

pub fn url_config_no_password_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(1234)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(None)
  assert pog.url_config(name, "postgres://u@db.test:1234/my_db") == Ok(expected)
}

pub fn url_config_no_port_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.port(5432)
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(None)
  assert pog.url_config(name, "postgres://u@db.test/my_db") == Ok(expected)
}

pub fn url_config_path_slash_test() {
  let name = process.new_name("pog_test")
  assert pog.url_config(name, "postgres://u:p@db.test:1234/my_db/foo")
    == Error(Nil)
}

pub fn url_config_percent_encoded_userinfo_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.database("my_db")
    |> pog.user("us@r")
    |> pog.password(Some("p@ss/word"))
  assert pog.url_config(name, "postgres://us%40r:p%40ss%2Fword@db.test/my_db")
    == Ok(expected)
}

pub fn url_config_colon_in_password_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.database("my_db")
    |> pog.user("u")
    |> pog.password(Some("p:a:ss"))
  assert pog.url_config(name, "postgres://u:p:a:ss@db.test/my_db")
    == Ok(expected)
}

pub fn url_config_query_without_sslmode_test() {
  let name = process.new_name("pog_test")
  let expected =
    pog.default_config(name)
    |> pog.host("db.test")
    |> pog.database("my_db")
    |> pog.user("u")
  assert pog.url_config(name, "postgres://u@db.test/my_db?application_name=app")
    == Ok(expected)
}

pub fn url_config_sslmode_test() {
  let name = process.new_name("pog_test")
  let url = fn(mode) { "postgres://u@db.test/my_db?sslmode=" <> mode }
  let ssl = fn(mode) {
    pog.url_config(name, url(mode))
    |> result.map(fn(config) { config.ssl })
  }
  assert ssl("disable") == Ok(pog.SslDisabled)
  assert ssl("allow") == Ok(pog.SslDisabled)
  assert ssl("prefer") == Ok(pog.SslDisabled)
  assert ssl("require") == Ok(pog.SslUnverified)
  assert ssl("verify-ca") == Ok(pog.SslVerified)
  assert ssl("verify-full") == Ok(pog.SslVerified)
  assert ssl("unknown") == Error(Nil)
}

pub fn inserting_new_rows_test() {
  let db = start_default()
  let sql =
    "
  INSERT INTO
    cats
  VALUES
    (DEFAULT, 'bill', true, ARRAY ['black'], now(), '2020-03-04'),
    (DEFAULT, 'felix', false, ARRAY ['grey'], now(), '2020-03-05')"
  let assert Ok(returned) = pog.query(sql) |> pog.execute(db.data)

  assert returned.count == 2
  assert returned.rows == []

  disconnect(db)
}

pub fn inserting_new_rows_and_returning_test() {
  let db = start_default()
  let sql =
    "
  INSERT INTO
    cats
  VALUES
    (DEFAULT, 'bill', true, ARRAY ['black'], now(), '2020-03-04'),
    (DEFAULT, 'felix', false, ARRAY ['grey'], now(), '2020-03-05')
  RETURNING
    name"
  let assert Ok(returned) =
    pog.query(sql)
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)

  assert returned.count == 2
  assert returned.rows == ["bill", "felix"]

  disconnect(db)
}

pub fn selecting_rows_test() {
  let db = start_default()
  let sql =
    "
    INSERT INTO
      cats
    VALUES
      (DEFAULT, 'neo', true, ARRAY ['black'], '2022-10-10 11:30:30.1', '2020-03-04')
    RETURNING
      id"

  let assert Ok(pog.Returned(rows: [id], ..)) =
    pog.query(sql)
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(db.data)

  let assert Ok(returned) =
    pog.query("SELECT * FROM cats WHERE id = $1")
    |> pog.parameter(pog.int(id))
    |> pog.returning({
      use x0 <- decode.field(0, decode.int)
      use x1 <- decode.field(1, decode.string)
      use x2 <- decode.field(2, decode.bool)
      use x3 <- decode.field(3, decode.list(decode.string))
      use x4 <- decode.field(4, pog.timestamp_decoder())
      use x5 <- decode.field(5, pog.calendar_date_decoder())
      decode.success(#(x0, x1, x2, x3, x4, x5))
    })
    |> pog.execute(db.data)

  assert returned.count == 1
  assert returned.rows
    == [
      #(
        id,
        "neo",
        True,
        ["black"],
        timestamp.from_calendar(
          calendar.Date(2022, calendar.October, 10),
          calendar.TimeOfDay(11, 30, 30, 100_000_000),
          calendar.utc_offset,
        ),
        calendar.Date(2020, calendar.March, 4),
      ),
    ]

  disconnect(db)
}

pub fn invalid_sql_test() {
  let db = start_default()
  let sql = "select       select"

  let assert Error(pog.PostgresqlError(code, name, message)) =
    pog.query(sql) |> pog.execute(db.data)

  assert code == "42601"
  assert name == "syntax_error"
  assert message == "syntax error at or near \"select\""

  disconnect(db)
}

pub fn insert_constraint_error_test() {
  let db = start_default()
  let sql =
    "
    INSERT INTO
      cats
    VALUES
      (900, 'bill', true, ARRAY ['black'], now(), '2020-03-04'),
      (900, 'felix', false, ARRAY ['black'], now(), '2020-03-05')"

  let assert Error(pog.ConstraintViolated(message, constraint, detail)) =
    pog.query(sql) |> pog.execute(db.data)

  assert constraint == "cats_pkey"

  assert detail == "Key (id)=(900) already exists."

  assert message
    == "duplicate key value violates unique constraint \"cats_pkey\""

  disconnect(db)
}

pub fn select_from_unknown_table_test() {
  let db = start_default()
  let sql = "SELECT * FROM unknown"

  let assert Error(pog.PostgresqlError(code, name, message)) =
    pog.query(sql) |> pog.execute(db.data)

  assert code == "42P01"
  assert name == "undefined_table"
  assert message == "relation \"unknown\" does not exist"

  disconnect(db)
}

pub fn insert_with_incorrect_type_test() {
  let db = start_default()
  let sql =
    "
      INSERT INTO
        cats
      VALUES
        (true, true, true, true)"
  let assert Error(pog.PostgresqlError(code, name, message)) =
    pog.query(sql) |> pog.execute(db.data)

  assert code == "42804"
  assert name == "datatype_mismatch"
  assert message
    == "column \"id\" is of type integer but expression is of type boolean"

  disconnect(db)
}

pub fn execute_with_wrong_number_of_arguments_test() {
  let db = start_default()
  let sql = "SELECT * FROM cats WHERE id = $1"

  assert pog.execute(pog.query(sql), db.data)
    == Error(pog.UnexpectedArgumentCount(expected: 1, got: 0))

  disconnect(db)
}

fn assert_roundtrip(
  db: actor.Started(_),
  value: a,
  type_name: String,
  encoder: fn(a) -> pog.Value,
  decoder: Decoder(a),
) -> actor.Started(_) {
  assert pog.query("select $1::" <> type_name)
    |> pog.parameter(encoder(value))
    |> pog.returning(decode.at([0], decoder))
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 1, rows: [value]))
  db
}

pub fn null_test() {
  let db = start_default()
  assert pog.query("select $1")
    |> pog.parameter(pog.null())
    |> pog.returning(decode.at([0], decode.optional(decode.int)))
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 1, rows: [None]))

  disconnect(db)
}

pub fn bool_test() {
  start_default()
  |> assert_roundtrip(True, "bool", pog.bool, decode.bool)
  |> assert_roundtrip(False, "bool", pog.bool, decode.bool)
  |> disconnect
}

pub fn int_test() {
  start_default()
  |> assert_roundtrip(0, "int", pog.int, decode.int)
  |> assert_roundtrip(1, "int", pog.int, decode.int)
  |> assert_roundtrip(2, "int", pog.int, decode.int)
  |> assert_roundtrip(3, "int", pog.int, decode.int)
  |> assert_roundtrip(4, "int", pog.int, decode.int)
  |> assert_roundtrip(5, "int", pog.int, decode.int)
  |> assert_roundtrip(-0, "int", pog.int, decode.int)
  |> assert_roundtrip(-1, "int", pog.int, decode.int)
  |> assert_roundtrip(-2, "int", pog.int, decode.int)
  |> assert_roundtrip(-3, "int", pog.int, decode.int)
  |> assert_roundtrip(-4, "int", pog.int, decode.int)
  |> assert_roundtrip(-5, "int", pog.int, decode.int)
  |> assert_roundtrip(10_000_000, "int", pog.int, decode.int)
  |> disconnect
}

pub fn float_test() {
  start_default()
  |> assert_roundtrip(0.123, "float", pog.float, decode.float)
  |> assert_roundtrip(1.123, "float", pog.float, decode.float)
  |> assert_roundtrip(2.123, "float", pog.float, decode.float)
  |> assert_roundtrip(3.123, "float", pog.float, decode.float)
  |> assert_roundtrip(4.123, "float", pog.float, decode.float)
  |> assert_roundtrip(5.123, "float", pog.float, decode.float)
  |> assert_roundtrip(-0.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-1.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-2.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-3.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-4.654, "float", pog.float, decode.float)
  |> assert_roundtrip(-5.654, "float", pog.float, decode.float)
  |> assert_roundtrip(10_000_000.0, "float", pog.float, decode.float)
  |> disconnect
}

pub fn numeric_test() {
  let db =
    start_default()
    |> assert_roundtrip(0.0, "numeric", pog.float, pog.numeric_decoder())
    |> assert_roundtrip(10.0, "numeric", pog.float, pog.numeric_decoder())
    |> assert_roundtrip(1.1, "numeric", pog.float, pog.numeric_decoder())
    |> assert_roundtrip(1.0, "numeric", pog.float, pog.numeric_decoder())

  assert pog.query("select 1::numeric")
    |> pog.returning(decode.at([0], pog.numeric_decoder()))
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 1, rows: [1.0]))

  assert pog.query("select 0::numeric")
    |> pog.returning(decode.at([0], pog.numeric_decoder()))
    |> pog.execute(db.data)
    == Ok(pog.Returned(count: 1, rows: [0.0]))

  disconnect(db)
}

pub fn text_test() {
  start_default()
  |> assert_roundtrip("", "text", pog.text, decode.string)
  |> assert_roundtrip("✨", "text", pog.text, decode.string)
  |> assert_roundtrip("Hello, Joe!", "text", pog.text, decode.string)
  |> disconnect
}

pub fn bytea_test() {
  start_default()
  |> assert_roundtrip(<<"":utf8>>, "bytea", pog.bytea, decode.bit_array)
  |> assert_roundtrip(<<"✨":utf8>>, "bytea", pog.bytea, decode.bit_array)
  |> assert_roundtrip(
    <<"Hello, Joe!":utf8>>,
    "bytea",
    pog.bytea,
    decode.bit_array,
  )
  |> assert_roundtrip(<<1>>, "bytea", pog.bytea, decode.bit_array)
  |> assert_roundtrip(<<1, 2, 3>>, "bytea", pog.bytea, decode.bit_array)
  |> disconnect
}

pub fn array_test() {
  let decoder = decode.list(decode.string)
  start_default()
  |> assert_roundtrip(["black"], "text[]", pog.array(pog.text, _), decoder)
  |> assert_roundtrip(["gray"], "text[]", pog.array(pog.text, _), decoder)
  |> assert_roundtrip(["g", "b"], "text[]", pog.array(pog.text, _), decoder)
  |> assert_roundtrip(
    [1, 2, 3],
    "integer[]",
    pog.array(pog.int, _),
    decode.list(decode.int),
  )
  |> disconnect
}

pub fn date_test() {
  start_default()
  |> assert_roundtrip(
    calendar.Date(2022, calendar.October, 11),
    "date",
    pog.calendar_date,
    pog.calendar_date_decoder(),
  )
  |> disconnect
}

pub fn nullable_test() {
  start_default()
  |> assert_roundtrip(
    Some("Hello, Joe"),
    "text",
    pog.nullable(pog.text, _),
    decode.optional(decode.string),
  )
  |> assert_roundtrip(
    None,
    "text",
    pog.nullable(pog.text, _),
    decode.optional(decode.string),
  )
  |> assert_roundtrip(
    Some(123),
    "int",
    pog.nullable(pog.int, _),
    decode.optional(decode.int),
  )
  |> assert_roundtrip(
    None,
    "int",
    pog.nullable(pog.int, _),
    decode.optional(decode.int),
  )
  |> disconnect
}

pub fn expected_argument_type_test() {
  let db = start_default()

  assert pog.query("select $1::int")
    |> pog.returning(decode.at([0], decode.string))
    |> pog.parameter(pog.float(1.2))
    |> pog.execute(db.data)
    == Error(pog.UnexpectedArgumentType("int4", "1.2"))

  disconnect(db)
}

pub fn expected_return_type_test() {
  let db = start_default()
  assert pog.query("select 1")
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)
    == Error(
      pog.UnexpectedResultType([
        decode.DecodeError(expected: "String", found: "Int", path: ["0"]),
      ]),
    )

  disconnect(db)
}

pub fn expected_five_millis_timeout_test() {
  let db = start_default()

  assert pog.query(
      "select sub.ret from (select pg_sleep(0.05), 'OK' as ret) as sub",
    )
    |> pog.timeout(5)
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)
    == Error(pog.QueryTimeout)

  disconnect(db)
}

pub fn expected_ten_millis_no_timeout_test() {
  let db = start_default()

  assert pog.query(
      "select sub.ret from (select pg_sleep(0.01), 'OK' as ret) as sub",
    )
    |> pog.timeout(50)
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)
    == Ok(pog.Returned(1, ["OK"]))

  disconnect(db)
}

pub fn expected_ten_millis_no_default_timeout_test() {
  let name = process.new_name("pog_test")
  let assert Ok(db) =
    default_config(name)
    |> pog.start

  assert pog.query(
      "select sub.ret from (select pg_sleep(0.01), 'OK' as ret) as sub",
    )
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db.data)
    == Ok(pog.Returned(1, ["OK"]))

  disconnect(db)
}

pub fn expected_maps_test() {
  let name = process.new_name("pog_test")
  let assert Ok(db) =
    pog.Config(..default_config(name), rows_as_map: True)
    |> pog.start

  let sql =
    "
    INSERT INTO
      cats
    VALUES
      (DEFAULT, 'neo', true, ARRAY ['black'], '2022-10-10 11:30:30', '2020-03-04')
    RETURNING
      id"

  let assert Ok(pog.Returned(rows: [id], ..)) =
    pog.query(sql)
    |> pog.returning(decode.at(["id"], decode.int))
    |> pog.execute(db.data)

  let assert Ok(returned) =
    pog.query("SELECT * FROM cats WHERE id = $1")
    |> pog.parameter(pog.int(id))
    |> pog.returning({
      use id <- decode.field("id", decode.int)
      use name <- decode.field("name", decode.string)
      use is_cute <- decode.field("is_cute", decode.bool)
      use colors <- decode.field("colors", decode.list(decode.string))
      use last_petted_at <- decode.field(
        "last_petted_at",
        pog.timestamp_decoder(),
      )
      use birthday <- decode.field("birthday", pog.calendar_date_decoder())
      decode.success(#(id, name, is_cute, colors, last_petted_at, birthday))
    })
    |> pog.execute(db.data)

  assert returned.count == 1
  assert returned.rows
    == [
      #(
        id,
        "neo",
        True,
        ["black"],
        timestamp.from_calendar(
          calendar.Date(2022, calendar.October, 10),
          calendar.TimeOfDay(11, 30, 30, 0),
          calendar.utc_offset,
        ),
        calendar.Date(2020, calendar.March, 4),
      ),
    ]

  disconnect(db)
}

pub fn expected_maps_in_transaction_test() {
  let name = process.new_name("pog_test")
  let assert Ok(db) =
    pog.Config(..default_config(name), rows_as_map: True)
    |> pog.start

  let sql =
    "
    INSERT INTO
      cats
    VALUES
      (DEFAULT, 'neo', true, ARRAY ['black'], '2022-10-10 11:30:30', '2020-03-04')
    RETURNING
      name"

  let assert Ok(pog.Returned(1, ["neo"])) =
    pog.transaction(db.data, fn(conn) {
      pog.query(sql)
      |> pog.returning(decode.at(["name"], decode.string))
      |> pog.execute(conn)
    })

  disconnect(db)
}

pub fn transaction_commit_test() {
  let db = start_default()
  let id_decoder = decode.at([0], decode.int)
  let assert Ok(_) = pog.query("truncate table cats") |> pog.execute(db.data)

  let insert = fn(db, name) {
    let sql = "
  INSERT INTO
    cats
  VALUES
    (DEFAULT, '" <> name <> "', true, ARRAY ['black'], now(), '2020-03-04')
  RETURNING id"
    let assert Ok(pog.Returned(rows: [id], ..)) =
      pog.query(sql)
      |> pog.returning(id_decoder)
      |> pog.execute(db)
    id
  }

  // A succeeding transaction
  let assert Ok(#(id1, id2)) =
    pog.transaction(db.data, fn(db) {
      let id1 = insert(db, "one")
      let id2 = insert(db, "two")
      Ok(#(id1, id2))
    })

  // An error returning transaction, it gets rolled back
  let assert Error(pog.TransactionRolledBack("Nah bruv!")) =
    pog.transaction(db.data, fn(db) {
      let _id1 = insert(db, "two")
      let _id2 = insert(db, "three")
      Error("Nah bruv!")
    })

  // A crashing transaction, it gets rolled back
  let _ =
    exception.rescue(fn() {
      pog.transaction(db.data, fn(db) {
        let _id1 = insert(db, "four")
        let _id2 = insert(db, "five")
        panic as "testing rollbacks"
      })
    })

  let assert Ok(returned) =
    pog.query("select id from cats order by id")
    |> pog.returning(id_decoder)
    |> pog.execute(db.data)

  let assert [got1, got2] = returned.rows
  let assert True = id1 == got1
  let assert True = id2 == got2

  disconnect(db)
}

fn insert_cat(db: pog.Connection, name: String) -> Nil {
  let sql =
    "INSERT INTO cats VALUES (DEFAULT, $1, true, ARRAY ['black'], now(), '2020-03-04')"
  let assert Ok(_) =
    pog.query(sql)
    |> pog.parameter(pog.text(name))
    |> pog.execute(db)
  Nil
}

fn cat_names(db: pog.Connection, prefix: String) -> List(String) {
  let assert Ok(returned) =
    pog.query("SELECT name FROM cats WHERE name LIKE $1 ORDER BY id")
    |> pog.parameter(pog.text(prefix <> "%"))
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db)
  returned.rows
}

pub fn nested_transaction_rollback_test() {
  let db = start_default()

  let assert Ok(Nil) =
    pog.transaction(db.data, fn(db) {
      insert_cat(db, "nested-rollback-outer")
      let assert Error(pog.TransactionRolledBack("inner")) =
        pog.transaction(db, fn(db) {
          insert_cat(db, "nested-rollback-inner")
          Error("inner")
        })
      Ok(Nil)
    })

  assert cat_names(db.data, "nested-rollback-") == ["nested-rollback-outer"]

  disconnect(db)
}

pub fn nested_transaction_enclosing_rollback_test() {
  let db = start_default()

  let assert Error(pog.TransactionRolledBack("outer")) =
    pog.transaction(db.data, fn(db) {
      insert_cat(db, "nested-enclosing-outer")
      let assert Ok(Nil) =
        pog.transaction(db, fn(db) {
          insert_cat(db, "nested-enclosing-inner")
          Ok(Nil)
        })
      Error("outer")
    })

  assert cat_names(db.data, "nested-enclosing-") == []

  disconnect(db)
}

pub fn deeply_nested_transaction_test() {
  let db = start_default()

  let assert Ok(Nil) =
    pog.transaction(db.data, fn(db) {
      insert_cat(db, "nested-deep-1")
      let assert Error(pog.TransactionRolledBack("level 2")) =
        pog.transaction(db, fn(db) {
          insert_cat(db, "nested-deep-2")
          let assert Error(pog.TransactionRolledBack("level 3")) =
            pog.transaction(db, fn(db) {
              insert_cat(db, "nested-deep-3")
              Error("level 3")
            })
          Error("level 2")
        })
      let assert Ok(Nil) =
        pog.transaction(db, fn(db) {
          insert_cat(db, "nested-deep-4")
          Ok(Nil)
        })
      Ok(Nil)
    })

  assert cat_names(db.data, "nested-deep-")
    == ["nested-deep-1", "nested-deep-4"]

  disconnect(db)
}

pub fn nested_transaction_crash_test() {
  let db = start_default()

  let assert Ok(Nil) =
    pog.transaction(db.data, fn(db) {
      insert_cat(db, "nested-crash-outer")
      let assert Error(_) =
        exception.rescue(fn() {
          pog.transaction(db, fn(db) {
            insert_cat(db, "nested-crash-inner")
            panic as "testing nested rollbacks"
          })
        })
      Ok(Nil)
    })

  assert cat_names(db.data, "nested-crash-") == ["nested-crash-outer"]

  disconnect(db)
}

pub fn aborted_transaction_test() {
  let db = start_default()

  let assert Error(pog.TransactionQueryError(pog.PostgresqlError(
    code: "25P02",
    name: "in_failed_sql_transaction",
    ..,
  ))) =
    pog.transaction(db.data, fn(db) {
      insert_cat(db, "aborted-transaction")
      // The error is ignored, but PostgreSQL aborts the transaction anyway
      let _ = pog.query("SELECT * FROM unknown_table") |> pog.execute(db)
      Ok(Nil)
    })

  assert cat_names(db.data, "aborted-transaction") == []

  disconnect(db)
}

pub fn default_timeout_test() {
  let name = process.new_name("pog_test")
  let assert Ok(db) =
    default_config(name)
    |> pog.default_timeout(5)
    |> pog.start
  let sleep = fn(db, query) {
    query
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(db)
  }
  let query =
    pog.query("select sub.ret from (select pg_sleep(0.05), 'OK' as ret) as sub")

  assert sleep(db.data, query) == Error(pog.QueryTimeout)
  assert sleep(pog.named_connection(name), query) == Error(pog.QueryTimeout)
  assert sleep(db.data, pog.timeout(query, 1000)) == Ok(pog.Returned(1, ["OK"]))

  disconnect(db)
}

pub fn transaction_default_timeout_test() {
  let name = process.new_name("pog_test")
  let assert Ok(db) =
    default_config(name)
    |> pog.default_timeout(5)
    |> pog.start

  let assert Error(pog.TransactionQueryError(pog.QueryTimeout)) =
    pog.transaction(db.data, fn(db) {
      pog.query("select pg_sleep(0.05)")
      |> pog.execute(db)
    })

  disconnect(db)
}
