$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'releases_diff'

@diff = ReleasesDiff.new()

puts "Working directory will be '#{@diff.temp_work_dir}'. Make sure to manually cleanup when done."

@diff.save_old_manifest()
@diff.fissile_validate_old_releases()
@diff.fissile_validate_current_releases()

puts "Print differences ..."

@diff.print_added_releases()
@diff.print_removed_releases()
@diff.print_changed_releases()

$stdout.flush
