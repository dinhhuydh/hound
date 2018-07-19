class CompleteBuild
  static_facade :call

  def initialize(pull_request:, build:, token:)
    @build = build
    @pull_request = pull_request
    @token = token
    @commenting_policy = CommentingPolicy.new(pull_request)
  end

  def call
    if build.completed?
      violations = consolidated_violations.select do |violation|
        commenting_policy.comment_on?(violation)
      end

      if violations.any? || build.review_errors.any?
        pull_request.make_comments(violations, build.review_errors)
      end

      set_commit_status
      track_subscribed_build_completed
    end
  end

  private

  attr_reader :build, :commenting_policy, :token, :pull_request

  def consolidated_violations
    violation_message_totals = Hash.new {|hash, key| hash[key] = 0}

    build.violations.each do |violation|
      violation.messages.each do |message|
        violation_message_totals[message] += 1
      end
    end

    similar_messages = []

    build.violations.each do |violation|
      consolidated_messages = violation.messages.select do |message|
        if violation_message_totals[message] < Hound::MAX_COMMENTS ||
          similar_messages.exclude?(message)

          similar_messages << message
        end
      end

      consolidated_messages = consolidated_messages.map do |message|
        if violation_message_totals[message] < Hound::MAX_COMMENTS
          message
        else
          "#{message} (Hound found #{violation_message_totals[message] - 1} similar #{"case".pluralize(violation_message_totals[message] - 1)})"
        end
      end

      violation.messages = consolidated_messages
    end

    build.violations
  end

  def track_subscribed_build_completed
    if build.repo.subscription
      user = build.repo.subscription.user
      analytics = Analytics.new(user)
      analytics.track_build_completed(build.repo)
    end
  end

  def set_commit_status
    if fail_build?
      commit_status.set_failure(build.violations_count)
    else
      commit_status.set_success(build.violations_count)
    end
  end

  def fail_build?
    hound_config.fail_on_violations? && build.violations_count > 0
  end

  def hound_config
    HoundConfig.new(commit: pull_request.head_commit, owner: build.repo.owner)
  end

  def commit_status
    CommitStatus.new(
      repo_name: build.repo_name,
      sha: build.commit_sha,
      token: token,
    )
  end
end
