require "pivotal_export_parser"
require "gitlab"
require "csv"
require "json"
require "byebug"
require "logger"

module GitlabMigration
  VERSION = "0.1.0"

  STATUS_TO_LABEL_MAPPING = {
    "unstarted" => "Unstarted",
    "started" => "Dev Started",
    "finished" => "TL code review",
    "delivered" => "For Deploy to Prod",
    "rejected" => "Update Post Code Review",
    "accepted" => "Closed"
  }

  Log = Logger.new("output.log")
  original_formatter = Logger::Formatter.new
  Log.formatter = proc do |severity, datetime, progname, msg|
    original_formatter.call(severity, datetime, progname, msg).tap(&method(:puts))
  end

  def self.migrate_pivotal_project(project_folder:, stories_csv_path:, gitlab_project:, gitlab_epic_id:)
    Log.info "Parsing #{stories_csv_path}"
    PivotalExportParser.parse(stories_csv_path) do |story_data|
      return if story_data[:type].nil? || story_data[:type] == :epic
      comments = story_data[:comment]
      owners = story_data[:owned_by]
      story_data[:project] = gitlab_project
      story_data[:epic_id] = gitlab_epic_id
      Log.info "Converting story ##{story_data[:id]} to issue"
      issue = convert_to_issue(story_data, project_folder)
      issue.save
    rescue StandardError => e
      Log.error "Error encountered during conversion of #{story_data[:id]} for #{story_data[:epic_id]}: #{e.message}"
    end
  end

  def self.get_user_id(project, name)
    @project_user_list ||= {}
    @project_user_list[project] ||= UserList.new(project)
    @project_user_list[project].get_id(name)
  end

  def self.get_username(project, name)
    @project_user_list ||= {}
    @project_user_list[project] ||= UserList.new(project)
    @project_user_list[project].get_username(name)
  end

  private

  def self.convert_to_issue(data, project_folder)
    Issue.new(data[:project], data[:title]).tap do |issue|
      # Set pivotal id for logs
      pivotal_id = data[:id]
      issue.pivotal_id = pivotal_id

      # Set mappable fields
      issue.created_at = data[:created_at]
      issue.description = data.fetch(:description, "")
      # issue.epic_id = data[:epic_id] # not working atm
      issue.weight = data[:estimate]
      # accepted_at does not include time so we set this to end of day
      # so it appears at the end of the history in case comments 
      # were made on the same day
      if data[:accepted_at]
        issue.closed_at = data[:accepted_at] + (23*60*60) + (59 * 60)
      end

      # Add unmappable fields at the end of description
      other_data = data.slice(:id, :type, :requested_by, :url)
      table_rows_str = other_data.inject([]) do |memo, (key, value)|
        memo.push("|#{key}|#{value}|") if value
        memo
      end.join("\r\n")
      table_rows_str += "|Owners|#{data[:owned_by].join(', ')}|" if data[:owned_by]&.any?
      table_str = "#### Pivotal Data\r\n| Field | Value |\r\n| ------ | ------ |\r\n"
      issue.description += "\r\n\r\n" + table_str + table_rows_str

      # Set assignees
      data[:owned_by].each do |owner|
        assignee_id = GitlabMigration.get_user_id(issue.project, owner)
        issue.assignee_ids.push(assignee_id) if assignee_id
      end if data[:owned_by]

      # Set status label
      if data[:current_state] != "accepted"
        issue.state = :opened
        issue.labels.push(convert_pivotal_status(data[:current_state]))
      else
        issue.state = :closed
      end

      # Set pivotal id as label
      issue.labels.push("piv:id:#{pivotal_id}")

      # Set epic_id as label
      issue.labels.push("epic::#{data[:epic_id]}")

      # Set old pivotal labels
      issue.labels.push(*convert_pivotal_labels(data[:labels])) if data[:labels]

      # Add attachments as one note
      attachments_folder = File.join(project_folder, pivotal_id)
      if Dir.exists?(attachments_folder) && !Dir.empty?(attachments_folder)
        issue.notes.push(AttachmentsNote.new(issue, attachments_folder))
      end

      # Add all old comments as notes
      data[:comment].each_with_index do |comment, idx|
        # pivotal export did not include timestamp for comments so we need to
        # add a second between each comment to ensure we get correct ordering
        issue.build_note(comment.author, comment.text, comment.created_at + idx + 1)
      end if data[:comment]
    end
  end

  def self.convert_pivotal_labels(string_label)
    string_label.split(',').map{ |label| "piv:#{label.strip}" }
  end

  def self.convert_pivotal_status(state)
    "Sts::#{STATUS_TO_LABEL_MAPPING[state.downcase]}"
  end

  class GitlabObject
    # Gitlab::Error::TooManyRequests
    def with_retry(max_retries=3, &block)
      begin
        retries ||= 0
        block.call
      rescue Gitlab::Error::TooManyRequests
        if (retries += 1) < max_retries
          Log.error "Too many requests made. Sleeping for 60 seconds."
          sleep(60)
          Log.error "Attempting request again. Retry ##{retries}"
          retry
        else
          Log.error "Max retries reached."
          raise "Max retries reached"
        end
      rescue Gitlab::Error::InternalServerError
        if (retries +1) < max_retries
          Log.error "Server responded with code 500."
          sleep(5)
          Log.error "Attempting request again. Retry ##{retries}"
          retry
        else
          raise "Max retries reached"
        end
      end
    end

    def with_sudo(name, &block)
      # disable for now since sudo doesn't work unless for non-admin users.
      # Gitlab.sudo = name ? GitlabMigration.get_username(project, name) : nil
      block.call
      # Gitlab.sudo = nil
    end
  end

  class UserList < GitlabObject
    def initialize(project)
      @project = project
      with_retry do
        Log.info "Collecting users info for project ##{project}"
        @user_info_by_name = Gitlab.all_members(project).inject({}) do |memo, user|
          memo[clean_name(user.name)] = { id: user.id, username: user.username }
          memo
        end
        Log.info "Got #{@user_info_by_name.count} user infos"
      end
    end

    attr_accessor :project

    def get_id(name)
      @user_info_by_name.fetch(clean_name(name), {})[:id]
    end

    def get_username(name)
      @user_info_by_name.fetch(clean_name(name), {})[:username]
    end
    
    private

    def clean_name(name)
      name.strip.downcase
    end
  end

  class Issue < GitlabObject
    def initialize(project, title)
      @project = project
      @title = title
      @notes = []
      @labels = []
      @assignee_ids = []
    end

    attr_accessor :id, :project, :title, :labels, :notes, :weight,
                  :epic_id, :description, :state, :created_at,
                  :pivotal_id, :closed_at, :assignee_ids

    def build_note(author, text, created_at)
      Note.new(self, author, text, created_at).tap do |note|
        notes << note
      end
    end

    def save
      # Create issue
      attrs = {
        description: description,
        created_at: created_at.iso8601,
        labels: labels.join(","),
        epic_id: epic_id,
        assignee_ids: assignee_ids
      }
      with_retry do
        Log.info "Saving story ##{pivotal_id} as Gitlab issue"
        result = Gitlab.create_issue(project, title, attrs)
        @id = result["iid"]
        Log.info "Issue ##{id} created."
      end

      # Save all notes
      notes.each(&:save)

      # Close issue if required
      if state == :closed
        with_retry do
          Log.info "Updating issue ##{id} state to close"
          Gitlab.edit_issue(project, id, state_event: 'close', updated_at: closed_at.iso8601)
        end
      end
    end
  end

  class Note < GitlabObject
    def initialize(issue, author, text, created_at)
      @issue = issue
      @author = author
      @text = text
      @created_at = created_at
    end

    attr_accessor :issue, :author, :text, :created_at

    def save
      raise "issue not yet saved" if issue.id.nil?
      with_retry do
        with_sudo(author) do
          Log.info "Saving note to issue ##{issue.id}"
          Gitlab.create_issue_note(project, issue.id, body, created_at: created_at.iso8601)
        end
      end
    end

    private

    # We're not able to set the user so the note is prepended with author name
    def body
      if author
        "**#{author}**: #{text}"
      else
        text
      end
    end

    def project
      issue.project
    end
  end

  class AttachmentsNote < Note
    def initialize(issue, attachments_path)
      @issue = issue
      @attachments_path = attachments_path
      @created_at = issue.created_at
    end

    def save
      raise "issue not yet saved" if issue.id.nil?
      @text = "#### Uploaded Files\r\n\r\n"
      # Upload each file and use markdown from return value
      Dir[File.join(@attachments_path, "*")].each do |filepath|
        with_retry do
          Log.info "Uploading file #{filepath} to project ##{project}."
          result = Gitlab.upload_file(issue.project, filepath)
          Log.info "File uploaded. URL: #{result['url']}"
          @text += "*#{result['alt']}*\r\n\r\n#{result['markdown']}\r\n\r\n---\r\n\r\n"
        end
      end
      super
    end
  end
end
