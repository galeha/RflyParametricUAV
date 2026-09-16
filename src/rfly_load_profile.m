function [cfg, params, report] = rfly_load_profile(profilePath)
%RFLY_LOAD_PROFILE Load, validate, and canonicalize a JSON vehicle profile.

profilePath = char(string(profilePath));
if ~isfile(profilePath)
    error("RflyParametricUAV:ProfileNotFound", ...
        "Profile does not exist: %s", profilePath);
end

try
    cfg = jsondecode(fileread(profilePath));
catch exception
    error("RflyParametricUAV:InvalidJson", ...
        "Could not parse profile %s: %s", profilePath, exception.message);
end

report = rfly_validate_profile(cfg);
if ~report.is_valid
    error("RflyParametricUAV:InvalidProfile", "%s", ...
        strjoin(string(report.errors), newline));
end
params = rfly_profile_to_model_params(cfg);
end

