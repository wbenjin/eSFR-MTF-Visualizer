%% eSFR_Nikon_GUI.m
%  eSFR MTF field map for the Nikon 24.5MP IMX410/IMX820 cameras.
%
%  Sensor : full-frame 35.9 × 23.9 mm
%           6048 × 4024 effective px  →  pixel pitch 5.94 µm
%
%  Pipeline: .NEF → raw2rgb → esfrChart → measureSharpness → 2-D contour
%
%  Requirements: MATLAB R2021a+
%                Image Processing Toolbox
%                Camera Support Package for Nikon

clear; close all; clc;

%% ── CONFIG ──────────────────────────────────────────────────────────────
RAW_FILE = '';          % '' → file picker; otherwise full path
PERCENT  = 50;          % 50 → MTF50, 30 → MTF30, …
CHANNEL  = 'luminance'; % 'red' | 'green' | 'blue' | 'luminance'
%% ────────────────────────────────────────────────────────────────────────

PIXEL_PITCH_UM = 5.94;

msgs = {};  % log messages displayed in the GUI panel

%% 1 ── Pick file ──────────────────────────────────────────────────────────
if isempty(RAW_FILE)
    [f, p] = uigetfile({'*.nef;*.NEF', 'Nikon NEF'; '*.*', 'All files'}, ...
                       'Select Nikon Z6III NEF file');
    if isequal(f, 0)
        msgbox('No file selected.', 'Cancelled', 'warn');
        return;
    end
    RAW_FILE = fullfile(p, f);
end
assert(isfile(RAW_FILE), 'File not found: %s', RAW_FILE);

%% 2 ── NEF → demosaiced sRGB ──────────────────────────────────────────────
RGB = raw2rgb(RAW_FILE);
[H, W, ~] = size(RGB);
exifStr = formatLensInfo(RAW_FILE);

msgs{end+1} = sprintf('Image size  :  %d × %d px', W, H);

%% 3 ── Detect eSFR chart ──────────────────────────────────────────────────
chart = esfrChart(RGB);

msgs{end+1} = sprintf('Chart style :  %s', chart.Style);

%% 4 ── Measure SFR / MTF ─────────────────────────────────────────────────
sharp = measureSharpness(chart, PercentResponse=PERCENT);

msgs{end+1} = sprintf('ROIs        :  %d measured  (%d high-confidence)', ...
              height(sharp), nnz(sharp.confidenceFlag));

%% 5 ── Extract MTF values and ROI centroids ───────────────────────────────
mtfCol  = sprintf('MTF%d', PERCENT);
chanIdx = struct('red', 1, 'green', 2, 'blue', 3, 'luminance', 4);
ci      = chanIdx.(lower(CHANNEL));
allROIs = chart.SlantedEdgeROIs;
n       = height(sharp);

mtf    = nan(n, 1);
cx_px  = nan(n, 1);
cy_px  = nan(n, 1);
conf   = false(n, 1);
roiIdx = nan(n, 1);
slope  = nan(n, 1);
reason = strings(n, 1);

for k = 1:n
    val       = sharp.(mtfCol)(k, :);
    mtf(k)    = val(ci);
    conf(k)   = sharp.confidenceFlag(k);
    roiIdx(k) = sharp.ROI(k);
    slope(k)  = sharp.slopeAngle(k);

    cmt = sharp.comment{k};
    if ischar(cmt) || (isstring(cmt) && ~ismissing(cmt))
        reason(k) = string(cmt);
    end

    bb = allROIs(sharp.ROI(k)).ROI;
    if any(isnan(bb)), continue; end
    cx_px(k) = bb(1) + bb(3) / 2;
    cy_px(k) = bb(2) + bb(4) / 2;
end

% Remove rows with missing data
ok     = ~isnan(mtf) & ~isnan(cx_px);
mtf    = mtf(ok);    cx_px  = cx_px(ok);   cy_px  = cy_px(ok);
conf   = conf(ok);   roiIdx = roiIdx(ok);  slope  = slope(ok);
reason = reason(ok);

assert(numel(mtf) >= 4, 'Need ≥4 valid ROIs; got %d.', numel(mtf));

% Collect low-confidence ROI table into msgs
if any(~conf)
    msgs{end+1} = '';
    msgs{end+1} = sprintf('  %-5s  %-9s  %s', 'ROI', 'slope[°]', 'reason');
    for j = find(~conf)'
        why = erase(reason(j), 'Sharpness measurement may not be accurate as ');
        if strlength(why) == 0, why = "(no comment)"; end
        msgs{end+1} = sprintf('  %-5d  %-9.2f  %s', roiIdx(j), slope(j), why);
    end
    msgs{end+1} = '';
end

%% 6 ── Convert to lp/mm; shift origin to sensor centre ───────────────────
pitch_mm = PIXEL_PITCH_UM * 1e-3;
mtfLpMm  = mtf / pitch_mm;

cx   = (cx_px - W / 2) * pitch_mm;
cy   = (cy_px - H / 2) * pitch_mm;
xLim = ([1 W] - W / 2) * pitch_mm;
yLim = ([1 H] - H / 2) * pitch_mm;

%% 7 ── Scattered interpolation onto regular grid ─────────────────────────
[Xg, Yg] = meshgrid(linspace(xLim(1), xLim(2), 240), ...
                    linspace(yLim(1), yLim(2), 180));
Finterp = scatteredInterpolant(cx, cy, mtfLpMm, 'natural', 'linear');
Mg      = Finterp(Xg, Yg);

%% 8 ── Unified GUI ────────────────────────────────────────────────────────
bg     = [0.55 0.55 0.58];  % axes / figure background
fg     = [0.00 0.00 0.00];  % text, lines, markers
gridCo = [0.30 0.30 0.32];  % grid lines

[~, fname, fext] = fileparts(RAW_FILE);

fig = figure('Color', bg, 'Position', [20 50 1400 750]);

% ── Layout constants (pixels; axes positions are normalised [l b w h])
%    Left column : MTF contour (full height)
%    Right column: chart detection (top) + histogram (middle) + log panel (bottom)
%    FIG_W / FIG_H are derived from the figure so changing Position above is enough.
FIG_W = fig.Position(3);  FIG_H = fig.Position(4);
SPLIT_X = 920;  % pixel x where the right column begins
BOT_H   = 200;  % height of the bottom-right log panel
HIST_H  = 170;  % height of the histogram panel

RW = 1-(SPLIT_X+25)/FIG_W;  % right-column normalised width (shared by all three)
RL = (SPLIT_X+10)/FIG_W;    % right-column normalised left edge

axMTF   = axes(fig, 'Position', [0.02, 0.02, SPLIT_X/FIG_W-0.03, 0.96], ...
               'Color', bg, 'XColor', fg, 'YColor', fg, ...
               'GridColor', gridCo, 'MinorGridColor', gridCo, 'GridAlpha', 0.5);
axChart = axes(fig, 'Position', [RL, (BOT_H+HIST_H+25)/FIG_H, RW, (FIG_H-BOT_H-HIST_H-40)/FIG_H]);
axHist  = axes(fig, 'Position', [RL, (BOT_H+10)/FIG_H,         RW, HIST_H/FIG_H], 'Color', 'white');
pnlLog = uipanel(fig, 'Units', 'normalized', 'BorderType', 'none', 'Position', [RL, 8/FIG_H, RW, (BOT_H-8)/FIG_H]);
txtLog = uitextarea(pnlLog, 'Editable', 'off', 'FontName', 'Courier New', 'FontSize', 12, ...
                   'Position', [0, 0, round(RW*FIG_W), BOT_H]);
pnlLog.SizeChangedFcn = @(src, ~) resizeFill(src, txtLog);

% ── Chart detection
axes(axChart);  % make current so displayChart draws here
displayChart(chart, displayGrayROIs=false, displayColorROIs=false);
title(axChart, 'Detected eSFR ROIs', 'Interpreter', 'none');

% ── Luminance histogram
%    16-bit uint16: normalise by 2^16-1
lum    = (0.2126*double(RGB(:,:,1)) + 0.7152*double(RGB(:,:,2)) + 0.0722*double(RGB(:,:,3))) / (2^16 - 1);
edges  = linspace(0, 1, 256);
c      = (edges(1:end-1) + edges(2:end)) / 2;
counts = histcounts(lum(:), edges, 'Normalization', 'probability');
area(axHist, c, counts, 'FaceColor', [0.75 0.75 0.75], 'EdgeColor', 'none');
xlim(axHist, [0 1]);
set(axHist, 'YTick', [], 'XTick', 0:0.25:1);
title(axHist, 'Luminance histogram', 'Interpreter', 'none', 'FontSize', 9);

% ── MTF surface: filled colour bands + labelled isolines
hold(axMTF, 'on');
contourf(axMTF, Xg, Yg, Mg, 24, 'LineStyle', 'none');
[C, hC] = contour(axMTF, Xg, Yg, Mg, 8, 'Color', fg, 'LineWidth', 0.6, 'LabelFormat', '%0.1f');
clabel(C, hC, 'FontSize', 8, 'Color', fg);
colormap(axMTF, parula);
cb = colorbar(axMTF);
cb.Label.String = sprintf('MTF%d  (lp/mm)', PERCENT);
cb.Color = fg;  cb.Label.Color = fg;

% ── ROI scatter: high-confidence (colour-mapped) and low-confidence (red)
hHigh = scatter(axMTF, cx( conf), cy( conf), 70, mtfLpMm( conf), 'filled', ...
                'MarkerEdgeColor', fg, 'LineWidth', 0.8);
hLow  = scatter(axMTF, cx(~conf), cy(~conf), 60, 'filled', ...
                'MarkerFaceColor', [0.80 0.10 0.10], 'MarkerEdgeColor', fg, 'LineWidth', 0.8);
addRoiTip(hHigh, roiIdx( conf), slope( conf), mtfLpMm( conf), strings(nnz(conf), 1));
addRoiTip(hLow,  roiIdx(~conf), slope(~conf), mtfLpMm(~conf), reason(~conf));

% ── Axes labels & title
axis(axMTF, 'ij'); axis(axMTF, 'image');
xlim(axMTF, xLim); ylim(axMTF, yLim);
xlabel(axMTF, 'X (mm)', 'Color', fg);
ylabel(axMTF, 'Y (mm)', 'Color', fg);
title(axMTF, sprintf('%s%s  —  %s', fname, fext, exifStr), ...
      'Interpreter', 'none', 'FontSize', 11, 'Color', fg);

% ── Legend (only when low-confidence ROIs are present)
if any(~conf)
    lgd = legend(axMTF, [hHigh, hLow], {'high-confidence ROI', 'low-confidence ROI'}, ...
                 'Location', 'southoutside', 'Orientation', 'horizontal');
    lgd.Color = bg;  lgd.TextColor = fg;  lgd.EdgeColor = gridCo;
end

grid(axMTF, 'on'); box(axMTF, 'on'); hold(axMTF, 'off');

% ── Final summary line → log panel
msgs{end+1} = sprintf('MTF%d (%s)  :  %.1f .. %.1f lp/mm  (mean %.1f)  |  %d ROIs  (%d high,  %d low)', ...
              PERCENT, CHANNEL, min(mtfLpMm), max(mtfLpMm), mean(mtfLpMm), ...
              numel(mtfLpMm), nnz(conf), nnz(~conf));
txtLog.Value = msgs;


%% ── Local functions ──────────────────────────────────────────────────────

function resizeFill(container, ctrl)
% Keep ctrl filling container; queries InnerPosition in pixels to avoid
% normalised-unit confusion when container.Units = 'normalized'.
    prevUnits        = container.Units;
    container.Units  = 'pixels';
    sz               = container.InnerPosition(3:4);
    container.Units  = prevUnits;
    ctrl.Position    = [0, 0, sz(1), sz(2)];
end

function addRoiTip(hScatter, roiIdx, slope, mtfLpMm, reason)
% Attach custom data-tips to a Scatter handle.
    if isempty(hScatter) || numel(roiIdx) == 0, return; end
    reason(strlength(reason) == 0) = "(high confidence)";
    hScatter.DataTipTemplate.DataTipRows = [
        dataTipTextRow('ROI',     roiIdx)
        dataTipTextRow('slope',   slope,   '%.2f°')
        dataTipTextRow('MTF',     mtfLpMm, '%.1f lp/mm')
        dataTipTextRow('comment', reason)
    ];
end

function s = formatLensInfo(filePath)
% Build a human-readable EXIF summary string.
    ri = rawinfo(filePath);
    et = ri.ExifTags;

    if et.ExposureTime >= 1
        expStr = sprintf('%.1fs', et.ExposureTime);
    else
        expStr = sprintf('1/%gs', round(1 / et.ExposureTime));
    end

    s = strjoin({ char(ri.LensInfo.LensModel), ...
                  sprintf('@ %gmm',  et.FocalLength), ...
                  sprintf('f/%.1f',  et.FNumber), ...
                  expStr, ...
                  sprintf('ISO %d',  et.ISOSpeedRatings) }, '  ');
end