require "xcodeproj"

project_path, bundle_id, team_id, profile_uuid = ARGV
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |candidate| candidate.name == "Unity-iPhone" }
abort "The Unity Xcode app target is missing." unless target

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  abort "The Unity Xcode app target has the wrong bundle ID." unless settings["PRODUCT_BUNDLE_IDENTIFIER"] == bundle_id

  settings["CODE_SIGN_STYLE"] = "Manual"
  settings["DEVELOPMENT_TEAM"] = team_id
  settings["CODE_SIGN_IDENTITY"] = "Apple Distribution"
  settings["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] = "Apple Distribution"
  settings["PROVISIONING_PROFILE_SPECIFIER"] = profile_uuid
  settings.delete("PROVISIONING_PROFILE")
end

attributes = project.root_object.attributes["TargetAttributes"] ||= {}
attributes[target.uuid] ||= {}
attributes[target.uuid]["ProvisioningStyle"] = "Manual"
attributes[target.uuid]["DevelopmentTeam"] = team_id
project.save
