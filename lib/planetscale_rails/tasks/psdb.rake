# frozen_string_literal: true

require "English"
require "yaml"
require "pty"
require "colorize"

databases = ActiveRecord::Tasks::DatabaseTasks.setup_initial_database_yaml

def puts_deploy_request_instructions
  ps_config = YAML.load_file(".pscale.yml")
  database = ps_config["database"]
  branch = ps_config["branch"]
  org = ps_config["org"]

  puts "Create a deploy request for '#{branch.colorize(:blue)}' by running:\n"
  puts "     pscale deploy-request create #{database} #{branch} --org #{org}\n\n"
end

def kill_pscale_process
  Process.kill("TERM", ENV["PSCALE_PID"].to_i) if ENV["PSCALE_PID"]
end

def delete_password
  password_id = ENV["PSCALE_PASSWORD_ID"]
  return unless password_id

  ps_config = YAML.load_file(".pscale.yml")
  database = ps_config["database"]
  branch = ps_config["branch"]

  command = "pscale password delete #{database} #{branch} #{password_id} #{ENV["SERVICE_TOKEN_CONFIG"]} --force"
  output = `#{command}`

  return if $CHILD_STATUS.success?

  puts "Failed to cleanup credentials used for PlanetScale connection. Password ID: #{password_id}".colorize(:red)
  puts "Command: #{command}"
  puts "Output: #{output}"
end

def db_branch_colorized(database, branch)
  "#{database.colorize(:blue)}/#{branch.colorize(:blue)}"
end

namespace :psdb do
  task check_ci: :environment do
    use_service_token = ENV["PSCALE_SERVICE_TOKEN"] && ENV["PSCALE_SERVICE_TOKEN_ID"]
    if ENV["CI"]
      raise "For CI, you can only authenticate using service tokens." unless use_service_token

      service_token_config = "--service-token #{ENV["PSCALE_SERVICE_TOKEN"]} --service-token-id #{ENV["PSCALE_SERVICE_TOKEN_ID"]}"

      ENV["SERVICE_TOKEN_CONFIG"] = service_token_config
    end
  end

  def create_connection_string
    ps_config = YAML.load_file(".pscale.yml")
    database = ps_config["database"]
    branch = ps_config["branch"]

    raise "You must have `pscale` installed on your computer".colorize(:red) unless command?("pscale")
    if branch.blank? || database.blank?
      raise "Could not determine which PlanetScale branch to use from .pscale.yml. Please switch to a branch by using: `pscale switch database-name branch-name`".colorize(:red)
    end

    short_hash = SecureRandom.hex(2)[0, 4]
    password_name = "planetscale-rails-#{short_hash}"
    command = "pscale password create #{database} #{branch} #{password_name} -f json #{ENV["SERVICE_TOKEN_CONFIG"]}"

    output = `#{command}`

    if $CHILD_STATUS.success?
      response = JSON.parse(output)
      puts "Successfully created credentials for PlanetScale #{db_branch_colorized(database, branch)}"
      host = response["access_host_url"]
      username = response["username"]
      password = response["plain_text"]
      ENV["PSCALE_PASSWORD_ID"] = response["id"]

      "mysql2://#{username}:#{password}@#{host}:3306/#{database}"
    else
      puts "Failed to create credentials for PlanetScale #{db_branch_colorized(database, branch)}"
      puts "Command: #{command}"
      puts "Output: #{output}"
      puts "Please verify that you have the correct permissions to create a password for this branch."
      exit 1
    end
  end

  desc "Create credentials for PlanetScale"
  task "create_creds" => %i[environment check_ci] do
    ENV["PSCALE_DATABASE_URL"] = create_connection_string
  end

  desc "Migrate the database for current environment"
  task migrate: %i[environment check_ci create_creds] do
    db_configs = ActiveRecord::Base.configurations.configs_for(env_name: ActiveRecord::Tasks::DatabaseTasks.env)

    unless db_configs.size == 1
      raise "Found multiple database configurations, please specify which database you want to migrate using `psdb:migrate:<database_name>`".colorize(:red)
    end

    puts "Running migrations..."

    Kernel.system("DATABASE_URL=#{ENV["PSCALE_DATABASE_URL"]} bundle exec rails db:migrate")

    puts "Finished running migrations\n".colorize(:green)
    puts_deploy_request_instructions
  ensure
    delete_password
  end

  namespace :migrate do
    ActiveRecord::Tasks::DatabaseTasks.for_each(databases) do |name|
      desc "Migrate #{name} database for current environment"
      task name => %i[environment check_ci create_creds] do
        puts "Running migrations..."

        name_env_key = "#{name.upcase}_DATABASE_URL"
        Kernel.system("#{name_env_key}=#{ENV["PSCALE_DATABASE_URL"]} bundle exec rails db:migrate:#{name}")

        puts "Finished running migrations\n".colorize(:green)
        puts_deploy_request_instructions
      ensure
        delete_password
      end
    end
  end

  namespace :schema do
    namespace :load do
      ActiveRecord::Tasks::DatabaseTasks.for_each(databases) do |name|
        desc "Load the current schema into the #{name} database"
        task name => %i[environment check_ci create_creds] do
          puts "Loading schema..."

          name_env_key = "#{name.upcase}_DATABASE_URL"
          Kernel.system("#{name_env_key}=#{ENV["PSCALE_DATABASE_URL"]} bundle exec rake db:schema:load:#{name}")

          puts "Finished loading schema."
        ensure
          delete_password
        end
      end
    end
  end

  namespace :rollback do
    ActiveRecord::Tasks::DatabaseTasks.for_each(databases) do |name|
      desc "Rollback #{name} database for current environment"
      task name => %i[environment check_ci create_creds] do
        puts "Rolling back migrations..."

        name_env_key = "#{name.upcase}_DATABASE_URL"
        Kernel.system("#{name_env_key}=#{ENV["PSCALE_DATABASE_URL"]} bundle exec rake db:rollback:#{name}")

        puts "Finished rolling back migrations.".colorize(:green)
      ensure
        delete_password
      end
    end
  end
end

def command?(name)
  `which #{name}`
  $CHILD_STATUS.success?
end
