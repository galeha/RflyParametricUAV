function rfly_write_3d_xml(cfg, outputPath)
%RFLY_WRITE_3D_XML Generate an RflySim3D vehicle XML from explicit visual data.

outputPath = char(string(outputPath));
outputFolder = fileparts(outputPath);
if ~isempty(outputFolder) && ~isfolder(outputFolder)
    mkdir(outputFolder);
end

fileId = fopen(outputPath, "w", "n", "UTF-8");
if fileId < 0
    error("RflyParametricUAV:XmlWriteFailed", ...
        "Could not create RflySim3D XML: %s", outputPath);
end
cleanup = onCleanup(@() fclose(fileId)); %#ok<NASGU>

visual = cfg.visual;
scale = double(visual.body_scale(:));
fprintf(fileId, '<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(fileId, '<vehicle>\n');
fprintf(fileId, '  <ClassID>%d</ClassID>\n', int32(visual.class_id));
fprintf(fileId, '  <DisplayOrder>1000</DisplayOrder>\n');
fprintf(fileId, '  <Name>%s</Name>\n', escapeXml(string(visual.name)));
fprintf(fileId, '  <Scale><x>%.9g</x><y>%.9g</y><z>%.9g</z></Scale>\n', scale);
fprintf(fileId, '  <AngEulerDeg><roll>0</roll><pitch>0</pitch><yaw>0</yaw></AngEulerDeg>\n');
fprintf(fileId, '  <body>\n');
fprintf(fileId, '    <isAnimationMesh>0</isAnimationMesh>\n');
fprintf(fileId, '    <MeshPath>%s</MeshPath>\n', escapeXml(string(visual.body_mesh_path)));
fprintf(fileId, '    <MaterialPath></MaterialPath><AnimationPath></AnimationPath>\n');
fprintf(fileId, '    <CenterHeightAboveGroundCm>%.9g</CenterHeightAboveGroundCm>\n', ...
    double(visual.center_height_cm));
fprintf(fileId, '    <NumberHeigthAboveCenterCm>20</NumberHeigthAboveCenterCm>\n');
fprintf(fileId, '  </body>\n');
fprintf(fileId, '  <ActuatorList>\n');

for index = 1:numel(visual.actuators)
    actuator = visual.actuators(index);
    position = double(actuator.position_cm(:));
    euler = double(actuator.euler_deg(:));
    axis = double(actuator.rotation_axis(:));
    fprintf(fileId, '    <Actuator>\n');
    fprintf(fileId, '      <MeshPath>%s</MeshPath><MaterialPath></MaterialPath>\n', ...
        escapeXml(string(actuator.mesh_path)));
    fprintf(fileId, '      <RelativePosToBodyCm><x>%.9g</x><y>%.9g</y><z>%.9g</z></RelativePosToBodyCm>\n', ...
        position);
    fprintf(fileId, '      <RelativeAngEulerToBodyDeg><roll>%.9g</roll><pitch>%.9g</pitch><yaw>%.9g</yaw></RelativeAngEulerToBodyDeg>\n', ...
        euler);
    fprintf(fileId, '      <RotationAxisVectorToBody><x>%.9g</x><y>%.9g</y><z>%.9g</z></RotationAxisVectorToBody>\n', ...
        axis);
    fprintf(fileId, '      <RotationModeSpinOrDefect>0</RotationModeSpinOrDefect>\n');
    fprintf(fileId, '    </Actuator>\n');
end

fprintf(fileId, '  </ActuatorList>\n');
fprintf(fileId, '  <OnboardCameras>\n');
fprintf(fileId, '    <camera><name>Chase_Camera</name>');
fprintf(fileId, '<RelativePosToBodyCm><x>-100</x><y>0</y><z>50</z></RelativePosToBodyCm>');
fprintf(fileId, '<RelativeAngEulerToBodyDeg><roll>0</roll><pitch>-15</pitch><yaw>0</yaw></RelativeAngEulerToBodyDeg></camera>\n');
fprintf(fileId, '  </OnboardCameras>\n');
fprintf(fileId, '</vehicle>\n');
end

function value = escapeXml(value)
value = replace(value, "&", "&amp;");
value = replace(value, "<", "&lt;");
value = replace(value, ">", "&gt;");
value = replace(value, '"', "&quot;");
value = replace(value, "'", "&apos;");
value = char(value);
end

