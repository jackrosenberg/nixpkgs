{
  lib,
  fetchFromGitHub,
  python3Packages,
}:

python3Packages.buildPythonApplication rec {
  version = "1.0.1";
  format = "setuptools";
  pname = "ipgrep";

  disabled = python3Packages.isPy27;

  src = fetchFromGitHub {
    owner = "jedisct1";
    repo = "ipgrep";
    rev = version;
    hash = "sha256-NrhcUFQM+L66KaDRRpAoC+z5s54a+1fqEepTRXVZ5Qs=";
  };

  patchPhase = ''
    mkdir -p ipgrep
    substituteInPlace setup.py \
      --replace "'scripts': []" "'scripts': { 'ipgrep.py' }"
  '';

  propagatedBuildInputs = with python3Packages; [
    pycares
    urllib3
    requests
  ];

  meta = with lib; {
    description = "Extract, defang, resolve names and IPs from text";
    mainProgram = "ipgrep.py";
    longDescription = ''
      ipgrep extracts possibly obfuscated host names and IP addresses
      from text, resolves host names, and prints them, sorted by ASN.
    '';
    license = licenses.mit;
    maintainers = with maintainers; [ leenaars ];
    platforms = platforms.all;
  };
}
