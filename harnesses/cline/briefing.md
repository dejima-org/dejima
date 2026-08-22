  export CLINE_DATA_DIR={{harness_state_dir}}
  cline history          # find this session's id
  cline --id <session-id>

(the session id is deliberately absent from this briefing: Cline mints one when
a run starts, which is after this text was written, so `cline history` is where
to read it. CLINE_DATA_DIR has to be set because this project's Cline state is
kept in that directory on the host rather than in ~/.cline/data - Cline indexes
every session it has ever run in a single database, so dejima gives each
project its own and one project's history is never another's context.)
