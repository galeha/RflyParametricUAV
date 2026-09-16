function manifest = rfly_build_model(profilePath, artifactDirectory)
%RFLY_BUILD_MODEL Build and package one parameterized RflySim DLL.

profilePath = char(string(profilePath));
artifactDirectory = char(string(artifactDirectory));
sourceFolder = fileparts(mfilename("fullpath"));
projectRoot = fileparts(sourceFolder);
modelFolder = fullfile(projectRoot, "model");
modelName = "ParametricUAV_Max";
modelPath = fullfile(modelFolder, modelName + ".slx");

[cfg, ~, report] = rfly_load_profile(profilePath);
if ~isfolder(artifactDirectory)
    mkdir(artifactDirectory);
end

previousProfile = getenv("RFLY_UAV_PROFILE");
setenv("RFLY_UAV_PROFILE", profilePath);
profileCleanup = onCleanup(@() setenv("RFLY_UAV_PROFILE", previousProfile)); %#ok<NASGU>
previousFolder = pwd;
cd(modelFolder);
folderCleanup = onCleanup(@() cd(previousFolder)); %#ok<NASGU>

open_system(modelPath);
slbuild(modelName);
GenerateModelDLLFile;

generatedDll = fullfile(modelFolder, modelName + ".dll");
if ~isfile(generatedDll)
    error("RflyParametricUAV:DllNotGenerated", ...
        "RflySim conversion did not produce %s.", generatedDll);
end

profileId = string(cfg.profile_id);
artifactDll = fullfile(artifactDirectory, profileId + ".dll");
artifactXml = fullfile(artifactDirectory, profileId + ".xml");
copyfile(generatedDll, artifactDll, "f");
rfly_write_3d_xml(cfg, artifactXml);

manifest.profile_id = char(profileId);
manifest.variant = char(string(cfg.variant));
manifest.profile_source = profilePath;
manifest.model_source = modelPath;
manifest.matlab_version = version;
manifest.generated_at = char(datetime("now", TimeZone="UTC", ...
    Format="yyyy-MM-dd'T'HH:mm:ssXXX"));
manifest.dll = artifactDll;
manifest.rfly3d_xml = artifactXml;
manifest.validation_warnings = report.warnings;

manifestPath = fullfile(artifactDirectory, "manifest.json");
fileId = fopen(manifestPath, "w", "n", "UTF-8");
if fileId < 0
    error("RflyParametricUAV:ManifestWriteFailed", ...
        "Could not create %s.", manifestPath);
end
cleanup = onCleanup(@() fclose(fileId)); %#ok<NASGU>
fprintf(fileId, "%s", jsonencode(manifest, PrettyPrint=true));
fprintf("Built %s\n", artifactDll);
end

