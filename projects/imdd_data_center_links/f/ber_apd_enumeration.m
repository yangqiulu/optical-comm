function berenum = ber_apd_enumeration(mpam, Tx, Fiber, Apd, Rx, sim)
%% Calculate BER for unamplified IM-DD link with APD using enumeration method

%% Pre calculations
Nsymb = mpam.M^sim.L; % number of data symbols 
dataTX = debruijn_sequence(mpam.M, sim.L).'; % de Bruijin sequence
dataTXext = repmat(dataTX, [1 + ceil(2*sim.Ndiscard/length(dataTX)), 1]);
% wextend('1D', 'ppd', dataTX, sim.Ndiscard); % periodic extension
% (requires Wavelet toolbox)
dataTXext([1:2*sim.L end-2*sim.L:end]) = 0; % set 2L first and last symbols to zero
N = sim.Mct*length(dataTXext); % total number of samples 

% change receiver filtering and equalization type
Rx.filtering = 'matched';
if ~strcmpi(Rx.eq.type, 'none') % if equalization is necessary
    Rx.eq.type = 'Fixed TD-SR-LE'; % always use fixed time-domain symbol rate LE for analysis
    Rx.eq.ros = 1;
end

% Frequency and time
[sim.f, sim.t] = freq_time(N, sim.fs);

% system frequency responses
[HrxPshape, H] = apd_system_received_pulse_shape(mpam, Tx, Fiber, Apd, Rx, sim);

% Ajust levels to desired transmitted power and extinction ratio
mpam = mpam.adjust_levels(Tx.Ptx, sim.rexdB);
AGC = 1/(mpam.a(end)*Apd.Geff*Fiber.link_attenuation(Tx.Laser.wavelength));

mpam = mpam.norm_levels; % normalizes levels but preserves extinction ratio

%% Modulated PAM signal
xk = mpam.signal(dataTXext);

%% DAC
xt = Tx.DAC.convert(xk, sim.f/sim.fs); 

%% Generate optical signal
IdealLaser = Tx.Laser; 
IdealLaser.RIN = -Inf;
IdealLaser.linewidth = 0;
% Note: Intensity and phase noise are not modeled here, since the number of 
% samples is not high enough to obtain accurate statistics 

% Modulate
% Note: as enumeration cannot modeled MZM distortion, modulator is assumed
% to be a directly modulated laser
Etx = Tx.Laser.modulate(xt, sim.fs);

Pt = abs(Etx).^2;

% Ensures that transmitted power is at the right level
Etx = Etx*sqrt(Tx.Ptx/mean(Pt));

%% Fiber propagation
Erx = Fiber.linear_propagation(Etx, sim.f, Tx.Laser.wavelength);

%% Direct detect
yt = Apd.detect(Erx, sim.fs, 'no noise');

%% Noise whitening filter
if sim.WhiteningFilter
    [~, yt] = Apd.Hwhitening(sim.f, mean(abs(Erx).^2), Rx.N0, yt);
end

%% Automatic gain control
yt = yt*AGC;
yt = yt - mean(yt) + mean(mpam.a);

%% ADC
% ADC performs filtering, quantization, and downsampling
% For an ideal ADC, ADC.ENOB = Inf
timeRefSignal = xt; % align filtered signal ytf to this reference
Rx.ADC.T = sim.Mct; % symbol-rate sampling 
Hrx = conj(HrxPshape);
Rx.ADC.Filter = Filter(Hrx);
yk = Rx.ADC.convert(yt, sim.f/sim.fs, timeRefSignal);

%% Equalization
[yd, Rx.eq] = equalize(Rx.eq, yk, HrxPshape, mpam, sim);

% Symbols to be discard in BER calculation
yd = yd(sim.Ndiscard+1:end-sim.Ndiscard);

%% Calculate signal-dependent noise variance after matched filtering and equalizer 
Ssh = Apd.varShot(abs(Erx).^2, 1)/2; % two-sided shot noise PSD

% Receiver filter
% For symbol-rate sampling linear equalizer = APD -> Whitening filter ->
% matched filter -> equalizer (in continuous time)
Hshot = H.apd.*H.w.*H.rx.*Rx.eq.Hff(sim.f/mpam.Rs); % Shot noise shape
BWshot = trapz(sim.f, abs(Hshot).^2); % two-sided shot noise bandwidth

Hthermal = H.w.*H.rx.*Rx.eq.Hff(sim.f/mpam.Rs); % thermal noise shape
BWthermal = trapz(sim.f, abs(Hthermal).^2); % two-sided thermal noise bandwidth

h2 = fftshift(real(ifft(ifftshift(Hshot))));
h = h2(cumsum(abs(h2).^2)/sum(abs(h2).^2) > 0.001 & cumsum(abs(h2).^2)/sum(abs(h2).^2) < 0.999);
hh = h.*conj(h); % |h(t)|^2
hh = hh/abs(sum(hh)); % normalize

Sshf = BWshot*conv(hh, Ssh);
Sshf = delay_signal(Sshf, -grpdelay(hh, 1, 1)); % remove delay due to equalizer

% Add thermal noise
Sshf = Sshf + Rx.N0/2*BWthermal;

% Normalize and sample
Sshd = Sshf(1:sim.Mct:end);
Sshd = (AGC)^2*Sshd(sim.Ndiscard+1:end-sim.Ndiscard);

%% Calculate error probabilities using Gaussian approximation for each transmitted symbol
if not(mpam.optimize_level_spacing) && isfield(sim, 'mpamOpt') && not(isempty(sim.mpamOpt)) % use threshlds swept in montecarlo simulation
    Pthresh = zeros(mpam.M-1, 1);
    mpamOpt = sim.mpamOpt;
    for k = 1:mpam.M-1
        Pthresh(k) = (mpam.a(k+1)-mpam.a(k))/(mpamOpt.a(k+1)-mpamOpt.a(k))*(mpamOpt.b(k) - mpamOpt.a(k)) + mpam.a(k);
    end
else
    Pthresh = mpam.b; % decision thresholds referred to the receiver
end

pe = zeros(mpam.M, 1); % symbol error probability for each level
dat = gray2bin(dataTX, 'pam', mpam.M); % fix index mapping
for k = 1:Nsymb
    sig = sqrt(Sshd(k));
    
    if dat(k) == mpam.M-1
        pe(dat(k)+1) = pe(dat(k)+1) + qfunc((yd(k)-Pthresh(end))/sig);
    elseif dat(k) == 0
        pe(dat(k)+1) = pe(dat(k)+1) + qfunc((Pthresh(1)-yd(k))/sig);
    else 
        pe(dat(k)+1) = pe(dat(k)+1) + qfunc((Pthresh(dat(k) + 1) - yd(k))/sig);
        pe(dat(k)+1) = pe(dat(k)+1) + qfunc((yd(k) - Pthresh(dat(k)))/sig);
    end
end

pe = real(pe)/Nsymb;

berenum = sum(pe)/log2(mpam.M);
