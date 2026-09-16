function report = rfly_validate_profile_file(profilePath)
%RFLY_VALIDATE_PROFILE_FILE Validate a profile and print a CLI report.

[cfg, ~, report] = rfly_load_profile(profilePath);
fprintf("Profile '%s' is valid for variant '%s'.\n", ...
    string(cfg.profile_id), string(cfg.variant));
for index = 1:numel(report.warnings)
    fprintf("WARNING: %s\n", string(report.warnings{index}));
end
end

