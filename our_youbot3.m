function our_youbot3()
close all;
disp('Program started');
%vrep = remApi('remoteApi', 'extApi.h');
vrep=remApi('remoteApi');
vrep.simxFinish(-1);
id = vrep.simxStart('127.0.0.1', 19997, true, true, 2000, 5);
if id < 0,
    disp('Failed connecting to remote API server. Exiting.');
    vrep.delete();
    return;
end
fprintf('Connection %d to remote API server open.\n', id);
 
% Make sure we close the connexion whenever the script is interrupted.
cleanupObj = onCleanup(@() cleanup_vrep(vrep, id));
 
% This will only work in "continuous remote API server service"
% See http://www.v-rep.eu/helpFiles/en/remoteApiServerSide.htm
res = vrep.simxStartSimulation(id, vrep.simx_opmode_oneshot_wait);
% We're not checking the error code - if vrep is not run in continuous remote
% mode, simxStartSimulation could return an error.
% vrchk(vrep, res);
 
% Retrieve all handles, and stream arm and wheel joints, the robot's pose,
% the Hokuyo, and the arm tip pose.
h = youbot_init(vrep, id);
h = youbot_hokuyo_init(vrep, h);
 
% Let a few cycles pass to make sure there's a value waiting for us next time
% we try to get a joint angle or the robot pose with the simx_opmode_buffer
% option.
pause(.2);
 
% Constants:
 
timestep = .05;
wheelradius = 0.0937/2; % This value may be inaccurate. Check before using.
 
% Min max angles for all joints:
armJointRanges = [-2.9496064186096,2.9496064186096;
    -1.5707963705063,1.308996796608;
    -2.2863812446594,2.2863812446594;
    -1.7802357673645,1.7802357673645;
    -1.5707963705063,1.5707963705063 ];
 
startingJoints = [0,30.91*pi/180,52.42*pi/180,72.68*pi/180,0];
 
% In this demo, we move the arm to a preset pose:
pickupJoints = [90*pi/180, 19.6*pi/180, 113*pi/180, -41*pi/180, 0*pi/180];
 
% Tilt of the Rectangle22 box
r22tilt = -44.56/180*pi;
 
 
% Parameters for controlling the youBot's wheels:
forwBackVel = 0; % Speed according to x axis
leftRightVel = 0; % Speed according to y axis
rotVel = 0; % Speed around z axis
prevOri = 0; prevLoc = 0;
prevErrRot = 0;
prevErrDr = 0;
 
disp('Starting robot');
 
% Set the arm to its starting configuration:
res = vrep.simxPauseCommunication(id, true); vrchk(vrep, res);
for i = 1:5,
    res = vrep.simxSetJointTargetPosition(id, h.armJoints(i),...
        startingJoints(i),...
        vrep.simx_opmode_oneshot);
    vrchk(vrep, res, true);
end
res = vrep.simxPauseCommunication(id, false); vrchk(vrep, res);
 
% Make sure everything is settled before we start
pause(2);
 
[res, homeGripperPosition] = ...
    vrep.simxGetObjectPosition(id, h.ptip,...
    h.armRef,...
    vrep.simx_opmode_buffer);
vrchk(vrep, res, true);
fsm = 'path';
 
RTr = [-1 0 7.5; 0 -1 7.5; 0 0 1];
StructEl = ones(9,9);
StructSeen = ones(4,4);
side_map = 15;
cell = 0.125;
prev_goal = [1,120];
map = zeros(side_map/cell, side_map/cell);
map_seen = true(side_map/cell, side_map/cell);
map_plot = false(side_map/cell, side_map/cell);

path = [];
step_path = ceil(1.25/cell);
cnt_rotate = 0;
cnt_drive = 0;
cnt_path = 0;
while true,
    tic
    if vrep.simxGetConnectionId(id) == -1,
        error('Lost connection to remote API.');
    end
    
    % We get back all the positions
    [res, youbotPos] = vrep.simxGetObjectPosition(id, h.ref, -1,...
        vrep.simx_opmode_buffer); %-1 is to retrieve the absolute position of the object
    vrchk(vrep, res, true);
    [res, youbotEuler] = vrep.simxGetObjectOrientation(id, h.ref, -1,...
        vrep.simx_opmode_buffer);
    vrchk(vrep, res, true);
    
    % Read data from the Hokuyo sensor:
    [pts, contacts] = youbot_hokuyo(vrep, h, vrep.simx_opmode_buffer);
    
    %We receive the seen points and the obstacles as coordinates in comparison to the youbot
    youbot2absTrans = transl(youbotPos) * trotx(youbotEuler(1)) * troty(youbotEuler(2)) * trotz(youbotEuler(3));
    youbot_abs = ceil( (homtrans(RTr,[youbotPos(1); youbotPos(2)]))/cell);
    pts_abs = homtrans(youbot2absTrans, pts);
    pts_final = homtrans(RTr,pts_abs(1:2,:));
    pts_final = ceil(pts_final/cell);
    
    % To make sure that the hukoyo data belongs to the matrix
    min_tmp2 = min(pts_final(2,:),side_map/cell);
    pts_final(2,:) = max(min_tmp2, 1);
    min_tmp1 = min(pts_final(1,:),side_map/cell);
    pts_final(1,:) = max(min_tmp1, 1);
    
    % We update the map
    % Map 2 is a trick to dilate only ones the wall
    map2 = zeros(size(map));
    map2(sub2ind(size(map), pts_final(2,contacts), pts_final(1,contacts))) = 1; % % http://nl.mathworks.com/company/newsletters/articles/matrix-indexing-in-matlab.html
    map2 = idilate(map2, StructEl);
    index_dilate = ((map2-map) == 1);
    map(index_dilate) = 1;
    map_plot(sub2ind(size(map), pts_final(2,contacts), pts_final(1,contacts))) = true;
    
    % We transfo the hukoyo data in the abs reference
    hokuyo1_abs = homtrans(youbot2absTrans,h.hokuyo1Pos.');
    hokuyo2_abs = homtrans(youbot2absTrans,h.hokuyo2Pos.');
    hokuyo1_map = ceil(homtrans(RTr, [hokuyo1_abs(1);hokuyo1_abs(2)])/cell);
    hokuyo2_map = ceil(homtrans(RTr, [hokuyo2_abs(1);hokuyo2_abs(2)])/cell);
    
    % We compute the box around the robot
    x_left_robot = max(1, (youbot_abs(1) - (5/cell)) );
    x_right_robot = min(length(map), (youbot_abs(1) + (5/cell)) );
    y_up_robot = min(length(map), (youbot_abs(2) + (5/cell)) );
    y_down_robot = max(1,(youbot_abs(2) - (5/cell)) );
    
    % We compute where we see the points in the map 
    [X,Y] = meshgrid(x_left_robot:1:x_right_robot, y_down_robot:1:y_up_robot); 
    X = reshape(X, 1, []);
    Y = reshape(Y, 1, []);

    in = inpolygon(X,Y, [hokuyo1_map(1) pts_final(1,:) hokuyo2_map(1)],...
                    [hokuyo1_map(2) pts_final(2,:) hokuyo2_map(2)]);                
   
    map_seen(sub2ind(size(map_seen), Y(in), X(in))) = 0;
    map_seen(sub2ind(size(map_seen), hokuyo1_map(2), hokuyo1_map(1))) = 0;
    map_seen(sub2ind(size(map_seen), hokuyo2_map(2), hokuyo2_map(1))) = 0;
    map_seen(sub2ind(size(map_seen), youbot_abs(2), youbot_abs(1))) = 0;
    map_seen(index_dilate) = 0;
    
    map_seen = imerode(map_seen,StructSeen);
    map_seen = idilate(map_seen,StructSeen);
    
    % We plot the map
    [row_map_seen, col_map_seen] = find(map_seen(:,:) == 1);
    [row, col] = find(map_plot(:,:) == 1);
    subplot(211)
    plot(col,row,'.k');
    if ~(isempty(path))
        hold on;
        plot(path(:,1),path(:,2),'.g');
        plot(via(cnt,1),via(cnt,2), '.b');
    end
    hold on;
    plot(youbot_abs(1),youbot_abs(2),'.m');
    hold off;
    xlim([1,side_map/cell]);
    ylim([1,side_map/cell]);
    subplot(212)
    plot(col_map_seen,row_map_seen,'.r');
    xlim([1,side_map/cell]);
    ylim([1,side_map/cell]);
    drawnow;
    
    if strcmp(fsm, 'path'),
        if cnt_path < 5 % During 5 times we put all speed to 0 
            forwBackVel = 0; % Robot must not move while computing because we loose VREP comm during this time
            leftRightVel = 0;
            rotVel = 0;
            h = youbot_drive(vrep, h, forwBackVel, leftRightVel, rotVel);
            cnt_path = cnt_path+1;
        else %  We compute a new path
                start = homtrans(RTr, [youbotPos(1);youbotPos(2)]);
                start =ceil(start/cell).';
                path=[];
                goal = findGoal(map_seen, prev_goal, cell); 
                prev_goal=goal;
                fprintf('Computing a new path \n');
                %Use of DT algorithm to move
                dx = DXform(map);
                dx.plan(goal)
                path = dx.path(start);
                
                % Use Dstar
                % DS = Dstar(map, 'quiet');
                % DS.plan(goal);
                % path = DS.path(start);
            
                % To take every x meters a point
                path = [start;path;goal]; % DT need
                %path = [start;path]; % Dstar need
            
                if size(path, 1)>2 % If there is at least 2 elements in the path, we only keep the via points and points ever
                    angles = (path(2:end,2)-path(1:end-1,2))./(path(2:end,1)-path(1:end-1,1));
                    ind_angles = [false(1); angles(2:end) ~= angles(1:end-1)];
                    ind_angles = find(ind_angles == 1);
                    true_index_via = [];
                    if(isempty(ind_angles))
                        true_index_via = [step_path:step_path:length(path)-1];
                        true_index_via = [true_index_via, length(path)];
                        via = path(true_index_via(:),:);
                    else
                        for i = 1:length(ind_angles)-1
                            true_index_via = [true_index_via, ind_angles(i):step_path:(ind_angles(i+1)-1)];
                        end
                        if length(ind_angles) == 1
                            true_index_via = [ind_angles];
                        end
                        true_index_via = [step_path:step_path:true_index_via(1),true_index_via, ind_angles(end), true_index_via(end)+step_path:step_path:(length(path)-1), length(path)];
                        via = path(true_index_via(:),:);
                        true_index_via = [1, true_index_via]; % Trick to know the path between previous via and next one
                    end
                elseif size(path, 1)==2
                    via = path(end,:);
                    true_index_via = [2];
                end
                q = double((via*cell).');
                q_ref = homtrans(inv(RTr),q);
                cnt = 1;
                if size(q_ref,2) > 1 && sqrt( (youbotPos(1)-q_ref(1,1))^2 + (youbotPos(2)-q_ref(2,1))^2) < 0.2
                    q_ref = q_ref(:,2:end);
                    via = via(2:end,:);
                    true_index_via = true_index_via(2:end);
                end
                fprintf('Computing a new path finished \n');
                fprintf('Rotate \n');
                fsm = 'rotate';
        end
    elseif strcmp(fsm, 'rotate'),
        forwBackVel = 0;
        [errRot, rotVel] = youbot_rotate(youbotPos(1), youbotPos(2), youbotEuler(3), q_ref(1,cnt), q_ref(2,cnt), prevErrRot);
        if (abs(errRot) < 0.025) && (abs(angdiff(prevOri, youbotEuler(3))) < 0.01),
            rotVel = 0;
            h = youbot_drive(vrep, h, forwBackVel, leftRightVel, rotVel);
            prevErrRot = 0;
            if cnt < length(true_index_via) && any(map(sub2ind(size(map), path((true_index_via(cnt):true_index_via(cnt+1)),2), path((true_index_via(cnt):true_index_via(cnt+1)),1)))) 
                cnt_path = 0;
                fsm = 'path';
            else
                prev_dist_target = sqrt( (youbotPos(1)-q_ref(1,cnt))^2 + (youbotPos(2)-q_ref(2,cnt))^2 );
                cnt_drive = 0;
                fsm = 'drive';
                fprintf('Drive \n');
            end
        end
        prevOri = youbotEuler(3);
        prevErrRot = errRot;
        
    elseif strcmp(fsm, 'drive'),
        
        cnt_drive = cnt_drive + 1;
        [errRot, rotVel] = youbot_rotate(youbotPos(1), youbotPos(2), youbotEuler(3), q_ref(1,cnt), q_ref(2,cnt), prevErrRot);
        prevErrRot = errRot;
        [curr_dist_target, errDr, forwBackVel] = youbot_velocity(youbotPos(1), youbotPos(2), q_ref(1,cnt), q_ref(2,cnt), prevErrDr);
        if cnt_drive == 5
            if abs(curr_dist_target) > (abs(prev_dist_target)) + 0.02
                forwBackVel = 0;
                rotVel = 0; % We do not need to rotate just to rear
                % If we passed the current point but we closer to next via points like that => go to the next one
                if cnt < size(via, 1) && sqrt((youbotPos(1)-q_ref(1,cnt+1))^2 + (youbotPos(2)-q_ref(2,cnt+1))^2) < sqrt( (q_ref(1,cnt+1)-q_ref(1,cnt))^2 + (q_ref(2,cnt+1)-q_ref(2,cnt))^2)
                    curr_dist_target = sqrt((youbotPos(1)-q_ref(1,cnt+1))^2 + (youbotPos(2)-q_ref(2,cnt+1))^2);
                    cnt = cnt+1;
                else
                    fsm = 'rotate';
                end
            end
            prev_dist_target = curr_dist_target;
            cnt_drive = 0;
        end
        prevErrDr = errDr;
        
        if ( abs(curr_dist_target) < 0.1 )
            forwBackVel = 0;
            h = youbot_drive(vrep, h, forwBackVel, leftRightVel, rotVel);
            if cnt < size(via, 1)
                cnt = cnt +1;
                prevErrDr = 0;
                prev_dist_target = sqrt( (youbotPos(1)-q_ref(1,cnt))^2 + (youbotPos(2)-q_ref(2,cnt))^2 );
                if prev_dist_target < 0.2 && (cnt+1) < size(via, 1) % If the next point is too closed we go to 2 points after
                    cnt = cnt +1;
                    prev_dist_target = sqrt( (youbotPos(1)-q_ref(1,cnt))^2 + (youbotPos(2)-q_ref(2,cnt))^2 );
                end
                fprintf('Next point \n');
                if abs(errRot) > 0.025
                    fsm = 'rotate';
                    fprintf('Rotate \n');   
                end
            else
                cnt_finished_path = 0;
                fsm = 'finished_curr_path';
            end
        elseif abs(errRot) > 0.1745 %&& abs(curr_dist_target) > 0.5 % 10�
             forwBackVel = 0;
             h = youbot_drive(vrep, h, forwBackVel, leftRightVel, rotVel);
             fsm = 'rotate';
             fprintf('Rotate \n');
        end
        
        if cnt < length(true_index_via) && any(map(sub2ind(size(map), path((true_index_via(cnt):true_index_via(cnt+1)),2), path((true_index_via(cnt):true_index_via(cnt+1)),1)))) 
            cnt_path = 0;
            fsm = 'path';
        end
        
        
    elseif strcmp(fsm, 'finished_curr_path'),
        h = youbot_drive(vrep, h, 0, 0, 0);
        cnt_finished_path = cnt_finished_path + 1;
        if cnt_finished_path == 20
            fprintf('Finished the current path \n');
            
            
            if(sum(map_seen(:)) > 10) % If they remain less than 10 elements to discover, we have all the map and can stop the navigation
                cnt_path = 0;
                fsm = 'path';
            else
                map_seen(:,:) = 0;
                cnt_finished = 0;
                fsm = 'finished';
            end
        end
    elseif strcmp(fsm, 'finished'),
        h = youbot_drive(vrep, h, 0, 0, 0);
        cnt_finished = cnt_finished + 1;
        if cnt_finished == 10
            pause(3);
            break;
        end
    else
        error(sprintf('Unknown state %s.', fsm));
    end
    
    % Update wheel velocities
    h = youbot_drive(vrep, h, forwBackVel, leftRightVel, rotVel);
    % Make sure that we do not go faster that the simulator
    elapsed = toc;
    timeleft = timestep-elapsed;
    if (timeleft > 0),
        pause(min(timeleft, .01));
    end
end
 
end % main function