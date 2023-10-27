use once_cell::sync::OnceCell;
use std::{fs::File, io::Write, path::PathBuf};

/// TOOL LOG FILE is the file that stores the logs of the support tool.
static TOOL_LOG_FILE: OnceCell<Option<File>> = OnceCell::new();

/// Method to be only used to print tool logs to console and write in file.
pub fn log(content: String) {
    println!("{content}");
    // NOTE: If we failed to write to log file can't do anything, just write
    // to stdout and return
    let _ = write_to_log_file(format!("{content}\n"))
        .map_err(|e| println!("Not be able to write to log file, error: {e}"));
}

/// Method to be only used to write in file.
pub(crate) fn write_to_log_file(content: String) -> Result<(), std::io::Error> {
    if let Some(mut file) = TOOL_LOG_FILE
        .get()
        .ok_or(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "LogFile not initialised!",
        ))?
        .as_ref()
    {
        file.write_all(content.as_bytes())?;
    }

    Ok(())
}

/// Method to initialise the TOOL_LOG_FILE once cell with a File.
pub(crate) fn init_tool_log_file(file_path: PathBuf) -> Result<(), std::io::Error> {
    TOOL_LOG_FILE
        .set(Some(File::create(file_path)?))
        .expect("Expect to be initialised only once");
    Ok(())
}
/// Method to initialise the TOOL_LOG_FILE once cell without a log file.
pub(crate) fn init_no_log_file() {
    TOOL_LOG_FILE
        .set(None)
        .expect("Expect to be initialised only once");
}

/// Flush the stream.
pub fn flush_tool_log_file() -> Result<(), std::io::Error> {
    if let Some(mut file) = TOOL_LOG_FILE
        .get()
        .ok_or(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "LogFile not initialised!",
        ))?
        .as_ref()
    {
        file.flush()?;
    }
    Ok(())
}
