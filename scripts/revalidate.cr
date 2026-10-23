# Check a database's current artifacts against their kinds' current schemas,
# as an update would, and report each kind whose schema no longer parses and
# each artifact that would fail validation. Read-only: it skips Artistry.open,
# whose schema setup writes to the database. Exits 1 if anything failed.
#
#   crystal run scripts/revalidate.cr -- path/to/database.db
require "../src/artistry"

path = ARGV[0]? || abort "usage: revalidate DATABASE"
abort "no such file: #{path}" unless File.file?(path)

checked = 0
failures = 0

DB.open("sqlite3://#{path}") do |db|
  kinds = db.query_all(
    "SELECT r.code, r.plugin, r.kind, s.json FROM registry r
     JOIN schema s ON s.code = r.code AND s.version = r.version
     ORDER BY r.code",
    as: {String, String, String, String}
  )

  kinds.each do |code, plugin, kind, json|
    label = "#{code} #{plugin}/#{kind}"
    schema = JSON.parse(json)

    begin
      Jargon::Schema.from_json_any(schema)
    rescue ex
      failures += 1
      puts "#{label}: invalid schema: #{ex.message}"
      next
    end

    rows = db.query_all(
      "SELECT id, data FROM artifact WHERE code = ? AND new_id IS NULL ORDER BY id",
      code, as: {Int64, String}
    )
    rows.each do |id, data|
      checked += 1
      Artistry::Validator.validate(Artistry::Validator.apply_defaults(JSON.parse(data), schema), schema)
    rescue ex : Artistry::ValidationError
      failures += 1
      puts "#{label} artifact #{id}: #{ex.message}"
    end
  end

  puts "#{kinds.size} kinds, #{checked} artifacts checked, #{failures} failed"
end

exit(failures.zero? ? 0 : 1)
