# Indexes (0.13): Artifact.where by several fields with no index, one
# index per field, and one composite index; what add_index costs; and what
# the first open of an older store costs, which turns its per-field indexes
# into claims over current versions only.
#
#   crystal run --release bench/indexes.cr -- 200000 /tmp/indexes.db
#
# Cattacula-like voice lines: 50,000 bits, 5 beats, 20 voices, 1% wav; a
# tenth have a second version, so superseded rows sit in the table too. The
# store is built on the first run and reused after; each run first puts back
# the indexes register(index:) made before 0.13.
#
# Measured 2026-10-23 at 200k (p50): with the composite index on voice bit
# beat fmt, lookups fixing leading fields 0.02-0.03 ms, bit alone 0.03 ms
# (a skip-scan), voice and a rare fmt 0.6 ms, voice alone 29-35 ms (10,000
# artifacts, mostly parsing them). With one index per field, 0.02-0.07 ms
# wherever bit is fixed, 1.8-2.1 ms for voice and a rare fmt, 20 ms for
# voice alone. With none, 50-74 ms: a scan. add_index over 200k 190-200 ms;
# the first open of an older store 475 ms (converting four indexes and
# analyzing), 0.4-0.9 ms after.
#
# These need full statistics. Sampled ones (PRAGMA optimize's default) put
# the code at about 2000 rows, as few as voice, and the planner then read
# the kind in id order by code: 55-73 ms for voice and voice+fmt.
require "../src/artistry"

n = (ARGV[0]? || "200000").to_i
path = ARGV[1]? || "indexes.db"
FIELDS = %w[voice bit beat fmt]

def ms(&) : Float64
  t = Time.instant
  yield
  (Time.instant - t).total_milliseconds
end

unless File.exists?(path)
  rng = Random.new(11)
  Artistry.open(path)
  Artistry.conn.exec("PRAGMA journal_mode = WAL")
  props = FIELDS.to_h { |f| {f, {type: "string"}} }
  Artistry::Registry.register(kind: "line", plugin: "bench", code: "L",
    schema: {type: "object", properties: props, required: FIELDS})
  took = ms do
    Artistry.transaction do
      ids = Array.new(n) do
        Artistry::Artifact.create("L", {voice: "voice#{rng.rand(20)}", bit: "b#{rng.rand(50_000)}",
                                        beat: rng.rand(5).to_s, fmt: rng.rand < 0.01 ? "wav" : "mp3"}).id
      end
      ids.sample(n // 10, rng).each do |id|
        a = Artistry::Artifact.find(id).not_nil!
        a.update({voice: a["voice"].as_s, bit: a["bit"].as_s, beat: rng.rand(5).to_s, fmt: a["fmt"].as_s})
      end
    end
  end
  puts "built #{n} artifacts (+#{n // 10} versions) in #{(took / 1000).round(1)} s"
  Artistry.close
end

# An older store again: one index per field, over every version.
Artistry.open(path)
Artistry::Registry.indexes("line").each do |index|
  index.plugins.each { |plugin| Artistry::Registry.drop_index("line", index.fields, plugin: plugin) }
end
FIELDS.each do |f|
  Artistry.conn.exec("CREATE INDEX idx_bench_line_#{f} ON artifact(json_extract(data, '$.#{f}')) WHERE code = 'L'")
end
Artistry.close

puts "rows in artifact: #{n + n // 10}"
puts "open an older store (converts #{FIELDS.size} indexes, optimizes): #{ms { Artistry.open(path) }.round} ms"
Artistry.close
puts "open it again: #{ms { Artistry.open(path) }.round(1)} ms"

row = Artistry.conn.query_one("SELECT data FROM artifact WHERE code = 'L' AND new_id IS NULL AND json_extract(data, '$.fmt') = 'wav' LIMIT 1", as: String)
v = JSON.parse(row)
voice, bit, beat = v["voice"].as_s, v["bit"].as_s, v["beat"].as_s

# The plan for the query Artifact.where makes, with the same values bound.
def plan(conds : Hash(String, String)) : String
  where = ["a.code = ?", "a.new_id IS NULL"] + conds.keys.map { |k| "json_extract(a.data, '$.#{k}') = ?" }
  sql = "SELECT #{Artistry::Artifact::FIND_COLUMNS} FROM artifact a JOIN identity i ON a.id = i.id " \
        "WHERE #{where.join(" AND ")} ORDER BY a.id"
  steps = [] of String
  args = ["L".as(DB::Any)] + conds.values.map(&.as(DB::Any))
  Artistry.conn.query("EXPLAIN QUERY PLAN #{sql}", args: args) do |rs|
    rs.each { rs.read; rs.read; rs.read; steps << rs.read(String) }
  end
  steps.reject(&.starts_with?("SEARCH i ")).join("; ")
end

def bench(label, conds : Hash(String, String), reps = 20, &)
  count = 0
  times = Array.new(reps) { ms { count = yield } }
  printf "  %-24s %8.3f ms  %6d artifacts  %s\n", label, times.sort[reps // 2], count, plan(conds)
end

lookups = -> do
  bench("voice+bit+beat", {"voice" => voice, "bit" => bit, "beat" => beat}) { Artistry::Artifact.where("L", voice: voice, bit: bit, beat: beat).size }
  bench("voice+bit", {"voice" => voice, "bit" => bit}) { Artistry::Artifact.where("L", voice: voice, bit: bit).size }
  bench("bit alone", {"bit" => bit}) { Artistry::Artifact.where("L", bit: bit).size }
  bench("voice+fmt=wav (rare)", {"voice" => voice, "fmt" => "wav"}) { Artistry::Artifact.where("L", voice: voice, fmt: "wav").size }
  bench("voice alone (5%)", {"voice" => voice}, 5) { Artistry::Artifact.where("L", voice: voice).size }
end

puts "== one index per field (as converted)"
lookups.call

puts "== no index"
FIELDS.each { |f| Artistry::Registry.drop_index("line", [f], plugin: "bench") }
Artistry.optimize
lookups.call

puts "== composite voice bit beat fmt"
puts "  add_index: #{ms { Artistry::Registry.add_index("line", FIELDS, plugin: "bench") }.round} ms"
Artistry.optimize
lookups.call

Artistry.close
