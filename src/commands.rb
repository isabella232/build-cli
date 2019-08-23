require_relative './pipeline_renderer'
require_relative './command'
require_relative './docker'

def upload_pipeline(context)
  yml = PipelineRenderer.new(context).render!
  res = Command.new("buildkite-agent", "pipeline", "upload").with_stdin([yml]).run!.raise!

  if res.success?
    puts "Successfully uploaded pipeline"
  end
end

def test_project(context, project, connector)
  DockerCommands.kill_all
  DockerCommands.run_tests_for(context, project, connector)
end

def build_images(context, tag)
  DockerCommands.kill_all
  raise "Invalid version to build images from." if tag.nil?

  tags_to_build = [tag.stringify]
  tags_to_build.push(infer_additional_tags(context, tag))

  DockerCommands.build(context, tag)
  DockerCommands.tag_and_push(context, tags_to_build.flatten.compact)

  # Because buildkite doesn't give us the underlying branch on a tagged build, we need to infer it.
  if context.tag.nil? || !context.tag.stable?
    trigger_dependent_pipeline(context.branch, tags_to_build)
  elsif context.tag.stable?
    trigger_dependent_pipeline("master", tags_to_build)
  end
end

def trigger_dependent_pipeline(channel, tags)
  pipeline_input = <<~EOS
    - trigger: \"prisma-cloud\"
      label: \":cloud: Trigger Prisma Cloud Tasks #{tags.join(", ")} :cloud:\"
      async: true
      build:
        env:
            BUILD_TAGS: \"#{tags.join(',')}\"
            CHANNEL: \"#{channel}\"
  EOS

  res = Command.new("buildkite-agent", "pipeline", "upload").with_stdin([pipeline_input]).run!.raise!
end

def infer_additional_tags(context, tag)
  additional_tags = []

  unless tag.nil?
    if tag.stable? || tag.beta?
      if tag.patch.nil?
        # E.g. not only tag 1.30(-beta), but also 1.30.0(-beta)
        additional_tag = tag.dup
        additional_tag.patch = 0
        additional_tags.push additional_tag.stringify
      else
        # E.g. not only tag 1.30.0(-beta), but also 1.30(-beta)
        additional_tag = tag.dup
        additional_tag.patch = nil
        additional_tags.push additional_tag.stringify
      end
    else
      if tag.revision.nil?
        # E.g. not only tag 1.30-beta, but also 1.30-beta-1
        additional_tag = tag.dup
        additional_tag.revision = 1
        additional_tags.push additional_tag.stringify
      else
        # E.g. not only tag 1.30-beta-1, but also 1.30-beta
        additional_tag = tag.dup
        additional_tag.revision = nil
        additional_tags.push additional_tag.stringify
      end
    end
  end

  additional_tags
end

# Eliminates consistency issues on buildkite
def git_fetch
  Command.new("git", "fetch", "--tags", "-f").run!.raise!
end