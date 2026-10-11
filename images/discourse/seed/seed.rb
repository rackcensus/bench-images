# frozen_string_literal: true

class Array
  RNG = Random.new(1_098_109_928_029_800)

  def sample
    self[RNG.rand(size)]
  end
end

Kernel.srand(1_098_109_928_029_800)

PASSWORD = "password12345abc"
USERS = 100

def sentence
  @gabbler ||=
    Gabbler.new.tap do |gabbler|
      story = File.read("/var/www/discourse/script/alice.txt")
      gabbler.learn(story)
    end

  sentence = +""
  until sentence.length > 800
    sentence << @gabbler.sentence
    sentence << "\n"
  end
  sentence
end

def create_user(seq, admin: false, username: nil)
  User.new.tap do |user|
    user.email = "user@localhost#{seq}.fake"
    user.username = username || "user#{seq}"
    user.password = PASSWORD
    user.save!

    if admin
      user.grant_admin!
      user.change_trust_level!(TrustLevel[4])
    end

    user.activate
  end
end

require "/var/www/discourse/config/environment"
require "json"
$LOAD_PATH.unshift(Dir.glob("/usr/local/lib/ruby/gems/*/gems/gabbler-*/lib").first || abort("gabbler is not installed"))
require "gabbler"

Jobs.run_immediately!
RateLimiter.disable

abort "only run this against an empty database" if User.human_users.exists?

puts "creating #{USERS} users"
USERS.times { |i| create_user(i) }
admin_user = create_user(USERS + 1, admin: true, username: "admin1")
users = User.human_users.to_a

puts "creating 10 categories"
categories = 10.times.map { |i| Category.create!(name: "category#{i}", text_color: "ffffff", color: "000000", user: admin_user) }

puts "creating 100 topics"
topic_ids =
  100.times.map do
    PostCreator.create(admin_user, raw: sentence, title: sentence[0..50].strip, category: categories.sample.id, skip_validations: true).topic_id
  end

puts "creating 2000 replies"
2000.times { PostCreator.create(users.sample, raw: sentence, topic_id: topic_ids.sample, skip_validations: true) }

puts "creating the perf test topic and its 100 replies"
first_post = PostCreator.create(users.sample, raw: sentence, title: "I am a topic used for perf tests", category: categories.sample.id, skip_validations: true)
100.times { PostCreator.create(users.sample, raw: sentence, topic_id: first_post.topic_id, skip_validations: true) }

Category.update_stats
Jobs::PeriodicalUpdates.new.execute(nil)

SiteSetting.max_logins_per_ip_per_minute = 100_000
SiteSetting.max_logins_per_ip_per_hour = 100_000
RateLimiter.enable

topic = Topic.find(first_post.topic_id)
manifest = {
  topic_path: "/t/#{topic.slug}/#{topic.id}",
  user_activity_path: "/u/admin1/activity",
  usernames: User.human_users.where("username LIKE 'user%'").order(:id).pluck(:username),
  password: PASSWORD,
  counts: { users: User.human_users.count, categories: Category.count, topics: Topic.where(archetype: "regular").count, posts: Post.count },
  versions: {
    discourse: Discourse.git_version,
    ruby: RUBY_VERSION,
    rails: Rails.version,
    postgres: ActiveRecord::Base.connection.select_value("SHOW server_version"),
    redis: Discourse.redis.info["redis_version"]
  }
}
File.write(ARGV.fetch(0), JSON.pretty_generate(manifest) + "\n")
puts "wrote #{ARGV.fetch(0)} with #{manifest[:counts].to_json}"
