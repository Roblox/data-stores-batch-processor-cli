# **Roblox Data Stores Batch Processor CLI: Technical Guide**

**⚠️ Use At Your Own Risk**

This CLI is a powerful tool to help creators better manage data in data stores. It directly interacts with your live experience data at bulk.

Batch data processing is a very complex process, and many things can go wrong. **Improper use, incorrect configurations, or errors in custom callback functions can result in permanent, irreversible data loss.** It is strongly recommended to test thoroughly on a test experience first.

**Please read this entire guide carefully before using this tool.** Please be especially cautious if you are doing a data migration while your experience is still reading / writing those keys. You will need to implement handling for this — this is called a live-path migration and is covered later in **Section 10**.

By using this tool, you acknowledge and accept all risks.

Welcome to the official guide for the Roblox Data Stores Batch Processor Command-Line Interface (CLI). This document provides technical guidance for installing, configuring, and operating the tool.

This tool is open source under the MIT License! Feel welcome to fork the repository and stage a pull request with your contributions. Please see the **[LICENSE](./LICENSE)** for details. This tool
uses third-party
modules; their licenses are listed in **[ATTRIBUTIONS.md](./ATTRIBUTIONS.md)**.

## **1\. Overview**

The Batch Processor CLI is a powerful command-line tool built on the Lune runtime. It performs large-scale, custom operations on your experience's data stores by leveraging memory stores, data stores, and `LuauExecutionSessionTasks` Open Cloud APIs.

The CLI orchestrates the entire workflow, from task creation to execution, while providing you with the necessary tools to actively manage and monitor your running batch processes.

### **1.1. Use Cases**

The tool allows you to run custom Luau logic across all keys within a data store or across all data stores within an experience. This enables a variety of powerful data operations, including:

- **Schema Migrations:** Updating the data structure for thousands or millions of user profiles after an update.
- **Bulk Data Deletion:** Removing specific data fields from all user accounts for data cleanup or compliance, or clearing obsolete data stores.

If you are a DataStore2 or Berezaa Method user, this tool will be especially useful for data migration and cleanup\!

### **1.2. How It Works**

At a high level, the tool operates by creating and managing `LuauExecutionSessionTasks` to execute your custom Luau scripts. The batch process is broken down into two stages:

- **Stage 1: Scan and Queue**  
  The first stage scans your experience to identify all target data stores or keys based on your provided criteria. It then populates a memory store queue with these items, which are considered "jobs" for the next stage. Stage 1 also accumulates progress as jobs are completed, updating overall batch process state.
- **Stage 2: Dequeue and Process**  
  The second stage dequeues the jobs created in Stage 1 and executes your custom Luau logic for each item within a job. This is where your data manipulation, migration, or analysis takes place.

If the batch process runs to completion, at-least-once processing is guaranteed.

## **2\. Getting Started**

Follow these steps to set up the CLI and prepare your environment.

### **2.1. Prerequisites**

1. **Unzip Module:** Unzip the provided Batch Processing module and save it to your local machine.
2. **Install Lune:** [Install the Lune runtime](https://lune-org.github.io/docs/getting-started/1-installation) on your machine. This is required to execute the tool.
3. **Configure Open Cloud API Key:** The tool requires an Open Cloud API Key with specific permissions.
   - Navigate to the [Creator Hub API Extensions](https://create.roblox.com/dashboard/credentials).
   - Create a new API Key or edit an existing one.
   - Grant the key the necessary permissions for your target experience, as detailed in **Appendix A: API Key Permissions**.
   - Save the generated API key to a secure location.

### **2.2. Running a Batch Process**

1. **Set API Key Environment Variable:** Before running a command, set your API Key as an environment variable. You can do this directly in your terminal, or see **Appendix F: Tips and Tricks** for
   further ways of securing your API Key.
   - **macOS/Linux (sh, bash, zsh):**  
     `export API_KEY="<Your-API-Key>"`
   - **Windows (PowerShell):**  
     `$env:API_KEY="<Your-API-Key>"`
2. **Create a Callback Function:** Write your custom processing logic in a Luau file. See **Appendix C: Custom Callback Function** for requirements and examples. This callback function will be called on **every key / data store scanned by the batch processor**. Each item will be processed independently.
3. **Execute Command:** Navigate to the top-level directory of the unzipped module and run one of the available commands (process-keys or process-data-stores). For example, call
   - `lune run batch-process process-keys mybatchprocess -c myconfig.json`

### **2.3 Foreground Process**

The batch process runs actively in the foreground, and you must **keep the terminal session open** for the entire duration of the job.

This is because the CLI performs a critical "keep-alive" function. Today Session Tasks have a finite lifetime (a 5-minute time limit) and can terminate for various reasons. The CLI actively monitors
these sessions and automatically restarts any that die to ensure that long-running batch processes can continue until completion. Closing the terminal will terminate this orchestration process. Batch
process state is stored in memory stores, so if the terminal closes, you can **resume** a previously-running batch process.

Note that if you exit out of the foreground process, the batch process will continue to execute until all Session Tasks terminate organically.

### **2.4 Cleaning up a Batch Process**

After a batch process finishes or fails, the process name continues to be reserved until the process is cleaned up. This allows you to review and keep a record of previously completed batch processes. To cleanup a batch process, you can call the `cleanup` command like so:

- `lune run batch-process cleanup mybatchprocess -c myconfig.json`

“Cleaning up” a batch process implies deleting the data stores / memory stores resources used for execution – see **Appendix D** for information on these resources.

## **3\. Best Practices**

Before executing a large-scale batch process on your production data, it is crucial to follow these testing and verification steps to prevent unintended consequences.

- **Test on a Non-Production Experience First**  
  Always run your batch process against a test data store with a smaller, representative dataset. This allows you to validate your callback logic and tune configurations in a safe environment without impacting live user data. Verify that the batch process is running using the [**Data Stores Observability Dashboard**](https://create.roblox.com/docs/cloud-services/data-stores/observability), and verify any changes to your data stores manually in [**Data Stores Manager**](https://create.roblox.com/docs/cloud-services/data-stores/data-stores-manager). Also ensure that your memory stores usage and error rate from the batch process is at acceptable levels with the [**Memory Stores Observability Dashboard**](https://create.roblox.com/docs/cloud-services/memory-stores/observability).
- **Perform a Scope Test**  
  Perform a “scope test” by running a batch process with an empty callback function on your keys / data stores. Given your `--key-prefix` or `--data-store-prefix`, observe how many items get captured by the batch process and ensure it coincides with your expected count.
- **Perform a Spot Test**  
  Once you are confident in your script and configurations, perform a limited "spot test" on your production environment. Use the `--key-prefix` or `--data-store-prefix` options to target a single, specific data point (e.g., your own test account’s key). Verify that the operation completes successfully and has the intended effect on that single item before running it on the entire dataset.
- **Verify All Configurations**  
  Before initiating a full run, double-check all provided configurations—either in your config file or as command-line options. **We have picked default configurations that work for most use cases, but they may not work for yours\!** Ensure all values are within reasonable limits for your use case and that you understand the performance implications of all configurations.
- **Monitor Batch Process Runs**  
  After starting a batch process, monitor the run for several minutes before walking away. Follow the same steps as discussed above in **Test on a Non-Production Experience First**.

## **4\. Command Reference**

### **4.1. process-keys**

Starts a batch process that iterates over key names within a single standard data store.

**Usage Examples:**

```sh
# Using direct command-line options
lune run batch-process process-keys <process-name> --data-store-name <name> [other-options...]

# Using a configuration file
lune run batch-process process-keys <process-name> --config <filepath>
```

**Arguments:**

- **`<process-name>`**: The unique name of the new batch process.

**Command-Specific Options:**

- **`--data-store-name / -d` :** The name of the data store to scan.
- **`--data-store-scope / -s` :** The scope of the data store.
- **`--key-prefix / -P` :** A prefix to filter which keys are processed.
- **`--exclude-deleted-keys` :** A flag to exclude keys that have been previously deleted.

**Shared Options:**  
This command also accepts all required options (`--universe-id`, etc.) and all optional processing configurations. **See Appendix B: Configuration Glossary** for the full list.

### **4.2. process-data-stores**

Starts a batch process that iterates over standard data store names within an experience.

**Usage Examples:**

```sh
# Using direct command-line options
lune run batch-process process-data-stores <process-name> --data-store-prefix <prefix> [other-options...]

# Using a configuration file
lune run batch-process process-data-stores <process-name> --config <filepath>
```

**Arguments:**

- **`<process-name>`** : The unique name of the new batch process.

**Command-Specific Options:**

- **`--data-store-prefix / -P`** : A prefix to filter which data stores are processed.

**Shared Options:**  
This command also accepts all required options (`--universe-id`, etc.) and all optional processing configurations. See **Appendix B: Configuration Glossary** for the full list.

### **4.3. resume**

Resumes a previously running batch process that has not completed. A batch process is considered incomplete if it fails, or if the terminal is closed and the session tasks time out before all items can be processed.

**Usage:**

```sh
# Using direct command-line options
lune run batch-process resume <process-name> --universe-id <id>

# Using a configuration file
lune run batch-process resume <process-name> --config <filepath>
```

**Arguments:**

- **`<process-name>`** : The unique name of the previously run batch process to resume.

**Option:**

- **`--universe-id / -u`** : The universe to load / resume the batch process on.

**Shared Options:**  
When resuming a process, all original configurations are loaded from the saved state. You can optionally override any of the following configurations:

- `numProcessingInstances`
- `outputDirectory`
- `errorLogMaxLength`
- `jobQueueMaxSize`
- `maxTotalFailedItems`
- `memoryStoresExpiration`
- `memoryStoresStorageLimit`
- `numRetries`
- `retryTimeoutBase`
- `retryExponentialBackoff`
- `processItemRateLimit`
- `progressRefreshTimeout`

**Important Notes**:

- Resuming will also **reload the callback function from the filepath**. Please ensure that the callback function and filepath are still correct before resuming a batch process.
- Resuming will **reset the output directory**. If you would like to save the previous output, then please change the outputDirectory configuration while resuming.
- When resuming a previously failed batch process, it is **required** that you set the `maxTotalFailedItems` to a value greater than the current failed item count.
- The new configurations are only applied to **new session tasks**. So, if you resume a batch process that still has active Session Tasks running, the process will continue with the old configurations until these sessions complete.

### **4.4. cleanup**

Cleans up an old batch process.

**Usage:**

```sh
# Using direct command-line options
lune run batch-process cleanup <process-name> --universe-id <id>

# Using a configuration file
lune run batch-process cleanup <process-name> --config <filepath>
```

**Command-Specific Arguments:**

- **`<process-name>`** : The unique name of the previously run batch process to resume.

**Option:**

- **`--universe-id / -u`** : The universe to load / resume the batch process on.

### **4.5. list**

Lists all batch processes.

**Usage:**

```sh
# Using direct command-line options
lune run batch-process list --universe-id <id>

# Using a configuration file
lune run batch-process list --config <filepath>
```

**Option:**

- **`--universe-id / -u`** : The universe to load / resume the batch process on.

## **5\. Configuration**

You can configure a batch process using a combination of a configuration file, command-line options, and interactive prompts. The tool uses a clear order of precedence to determine the final configurations for a run.

### **Order of Precedence**

Configurations are applied in the following order, with later methods overriding earlier ones:

1. **Default Values:** Built-in defaults for optional configurations.
2. **Configuration File:** Configurations loaded from a JSON file specified with the `-c` / `--config` flag.
3. **Command-Line Options:** Flags passed directly in the command (e.g., `--num-retries 5`). These will always override any values set in a config file.
4. **Interactive Prompts:** For any _required_ configurations not provided by the methods above, the CLI will prompt for input.

### **Recommended Workflow**

A powerful way to use the CLI is to combine a configuration file with command-line overrides. This allows you to maintain consistent base configurations while retaining flexibility.

1. **Create a base config.json file** with your common configurations (like universeId, placeId, and default processing parameters).
2. **Use command-line options** to override specific configurations for a particular run.

**_Example:_**  
Imagine `my_config.json` sets `numRetries` to `3`. You can override it for a single run:

```sh
# This run will use numRetries = 5, overriding the value from the file.
# All other settings will be loaded from my_config.json.
lune run batch-process process-keys my_process -c my_config.json --num-retries 5
```

See **Appendix B: Configuration Glossary** for a full list of available options.

## **6\. Observability and Debugging**

### **6.1. Output Files**

The CLI generates an output directory for each batch process, providing tools for monitoring and debugging. To inspect session details and logs, you must call the Open Cloud endpoints with your API key included in the **x-api-key** header.

- **`failed_items.output`**  
  Contains a line-separated record for each item that failed processing.  
  **_Format:_** `<item_name>|<error_time>|<truncated_error_log>|<session_path>`  
  Metadata for failed items (such as error time, logs, and session path) is never guaranteed, and will always be lost upon resuming a batch process. For persistent error tracking, please ensure this information is saved to a separate location before resuming a batch process.
- **`process.output`**  
  Displays the current status of the process along with its active configurations.
- **`stage1_session_paths_active.output & stage2_session_paths_active.output`**  
  Lists the session paths for currently active Stage 1 (scanning) and Stage 2 (processing) tasks. Note that logs are only available after a session completes.  
  Example Request: `GET https://apis.roblox.com/cloud/v2/<session_path>`
- **`stage1_session_paths_complete.output & stage2_session_paths_complete.output`**  
  An archive of session paths that have completed execution.
- **`session_logs directory`**  
  Contains a file for each completed sessions’ task logs. Each log file’s name is `<task ID>.output`, where the task ID is the final component of the session path.
- **`cli.output`**  
  A list of warnings and other debugging messages coming directly from the CLI. You will likely not need to use this, but in cases of unexpected behavior it may contain insights into the issue.

Given a session path from `failed_items.output` or `stage[1/2]_session_paths_[active/complete].output`, you can find its logs in the `session_logs` directory.

Alternatively, you can manually query the session task status or logs by requesting the following Open Cloud endpoints. Include your API key in the `x-api-key` header before making the requests:

- **Query Task Status:**  
  `GET https://apis.roblox.com/cloud/v2/<session_path>`
- **Query Logs:**  
  `GET https://apis.roblox.com/cloud/v2/<session_path>/logs`

### **6.2. Troubleshooting**

If a batch process appears to be stalled or not working as expected, follow these diagnostic steps. Some circumstances can cause it to fail or to _appear_ unresponsive while it is still running in the background.

1. **Check Memory Stores Dashboard:** The first step is to verify that the process is actually running. The CLI's orchestration logic heavily uses memory stores.
   - Navigate to your **Memory Stores Dashboard** on the Creator Hub.
   - Check for read and write activity. A running process will generate continuous activity. This is the primary indicator that the tool is operational.
   - Ensure that your experience has **available memory stores quota**. If your experience is out of available storage or Request Units, the batch process may stall.
2. **Inspect Session Logs for Completed Tasks:** If memory stores are active but you see no progress, a session may have completed or errored out.
   - Wait for a session path to appear in one of the ...\_complete.output files in your output directory.
   - Once a path appears, check for its logs in the session_logs directory, or query the Open Cloud endpoint directly.
   - Reading these logs can help diagnose issues within the Luau callback script or reveal problems like exceeding memory store storage limits, which might prevent the process from updating its state.
   - Note that there may be warning messages implying that the process has hit its configured `memoryStoresStorageLimit`. These are not indicative of your experience being fully out of memory stores
     quota -- to be certain, we recommend checking your memory stores dashboard.
3. **Review the cli.output File:** In rare cases, the CLI itself may encounter an unrecoverable error.
   - Check the cli.output file in your output directory.
   - This file contains critical errors related to the CLI's internal operations. An error in this file indicates an issue with the tool itself, rather than with the Luau scripts it is orchestrating. The CLI has built-in retry logic for all essential operations; if it exhausts its retries, it will terminate and log the final error here.

## **7\. Performance Tuning and Resource Management**

This section provides guidance on how to configure the CLI to balance processing speed with resource consumption.

### **7.1. Understanding and Managing Memory Stores Usage**

The CLI uses memory stores for job orchestration. Before starting a process, the tool will provide you with an **estimated upper bound for memory stores usage** (both for access in Request Units/min and for storage in KB) based on your configurations. This allows you to assess the potential impact on your experience, especially if it has low concurrent users (CCU) or already uses memory stores heavily.

You can further control resource consumption with the `--memory-stores-storage-limit` option. This sets a safety cap (in kilobytes) for the batch process. If the tool detects that storage usage is approaching this limit, it will automatically slow down or pause the Stage 1 scanning process to allow the Stage 2 workers to clear the job queue. This reduces memory pressure and prevents the process from failing due to storage limits.

Be especially wary of your storage quota. If the storage limit is ever reached, the batch processor may freeze indefinitely, and you may need to flush your memory stores or cleanup your batch process.

### **7.2. Optimizing for Processing Speed vs. Resource Usage**

Tuning your batch process involves a trade-off between speed and the consumption of memory store resources. The configurations with the largest impact are `numProcessingInstances`, `maxItemsPerJob`, and `jobQueueMaxSize`.

#### **To Maximize Processing Speed:**

- **Do:** Increase `numProcessingInstances`. This is the primary lever for speed, as it increases the number of concurrent workers processing items.
- **Do:** Increase `maxItemsPerJob`. This allows the Stage 1 scanner to enqueue jobs more quickly by fetching more items per List call, which helps keep your processing instances fed with work.
- **Be Aware:** This strategy will significantly increase both memory store access (RU/min) and storage usage. It is best suited for experiences with high CCU and a large memory store quota.

#### **To Minimize Memory Stores Storage / Access Impact:**

This is recommended for experiences with low CCU or those that already use memory stores heavily for live game features.

- **Do:** Use a lower `numProcessingInstances` (e.g., 1-3). This is the most effective way to reduce memory store access usage.
- **Do:** Keep `jobQueueMaxSize` at a low value (e.g., the default of 20). A large queue is unnecessary if the processing rate is slower and only serves to consume storage.
- **Do:** Keep `maxItemsPerJob` at a moderate value. A smaller job size reduces the amount of data stored in the queue at any given time.
- **Be Aware:** This will result in a slower overall batch process but ensures the tool has a minimal footprint on your experience's resources.

#### **What Not to Do:**

- **Don't** set `jobQueueMaxSize` to a very high number unless you have a specific reason. The queue is unlikely to fill up in most scenarios, and a large value primarily consumes unnecessary storage.
- **Don't** set `maxItemsPerJob` so high that a single job cannot be completed within the 5-minute `LuauExecutionSessionTask` lifetime. A safe upper bound is `maxItemsPerJob < processItemRateLimit * 4`.

The default optional configurations are tuned to suffice for most batch processing scenarios. However, it is ultimately up to you to tune the configurations to your particular use case.

## **8\. Example Use Case: Data Deletion**

Deleting all data in a single, obsolete data store can be done using the Delete Data Store API directly from the Data Stores Manager on Creator Hub. However, this may take up to 30 days to reduce your storage footprint. To delete data faster, you may use the batch processor. Please take caution that you are only deleting data from a data store that you are **no longer using**.

1. **Create a Deletion Callback:** Use the following callback with optional logging:

```
local DataStoreService = game:GetService("DataStoreService")
local dataStoreToDelete = DataStoreService:GetDataStore("<INSERT DATA STORE NAME>", "<INSERT DATA STORE SCOPE>")

return function(item)
	...
	-- <ADD OPTIONAL LOGGING HERE>
	...
	dataStoreToDelete:RemoveAsync(item)
end
```

2. **Create the Configuration File** (or provide arguments on the command line)
3. **Run the `process-keys` command to kick off the deletion:** e.g.  
   `lune run batch-process process-keys DS_DELETION_JUNE17 -c <config filepath>.json`

On a related note, bulk Data Store deletion can be achieved by integrating the Deletion API with the batch processor. Please take caution that you are only deleting data stores that you are no longer
using.

1. **Create a Deletion Callback:** Use the following callback with optional logging:

```
local DataStoreService = game:GetService("DataStoreService")
local dataStoreToDelete = DataStoreService:GetDataStore("<INSERT DATA STORE NAME>", "<INSERT DATA STORE SCOPE>")

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

return function(item)
	...
	-- <ADD OPTIONAL LOGGING HERE>
	...
	local encodedDataStoreName = HttpService:UrlEncode(dataStoreName)
	local apiKey = HttpService:GetSecret(<insert your api key secret here>)
	local response = HttpService:RequestAsync({
		Url = "https://apis.roblox.com/cloud/v2/universes/" .. UNIVERSE_ID
.. "/data-stores/" .. encodedDataStoreName,
		Method = "DELETE",
		Headers = {
			["x-api-key"] = apiKey,
			["Content-Type"] = "application/json
		},
	})
	...
	-- <ADD OPTIONAL LOGGING HERE>
	...
end
```

2. **Create the Configuration File** (or provide arguments on the command line)
3. **Run the `process-data-stores` command to kick off the deletion:** e.g.  
   `lune run batch-process process-data-stores DS_DELETION_JUNE17 -c <config filepath>.json`

## **9\. Example Use Case: Data Migrations**

### **9.1. General Migration Strategy**

When performing a large-scale data migration, it is critical to handle cases where users might join your experience mid-migration. This requires a robust strategy to ensure data integrity.

1. **Implement a Live-Path Migration:** Before starting the batch process, implement and deploy live-server code that handles migration for any user who joins the experience. This "live path" ensures that active users are migrated on-the-fly. This logic must use a **migration marker** to indicate that data has been migrated.
2. **Use a Migration Marker:** A migration marker is a piece of data or any signifier that indicates a specific key has already been migrated. Your callback function for the batch process **must** check for this marker before attempting to migrate data. This prevents the batch process from overwriting data that was already migrated by the live-path logic, making the process idempotent (safe to run multiple times).
3. **Recommended Marker Patterns:**
   - **Writing to a New Data Store (Recommended):** The safest approach is to read data from the old data store and write the migrated data to a _new_ data store. The migration marker is simply the existence of the key in the new data store. Your callback logic would be: if the key exists in the new store, do nothing; otherwise, perform the migration.
   - **Adding a Marker Property (In-Place Migration):** If you are overwriting data in the _same_ data store, you must add a "marker" property to the data object itself, or to the data store metadata (e.g., `isMigrated = true` or `schemaVersion = 2`). Your callback logic must first check if this property exists and has the correct value before proceeding.

By combining a live-path migration with a marker check in your batch callback, you create an idempotent process that is safe to run on live experiences.

### **9.2. Specific Example: DataStore2 Migration \+ Deletion**

The tool can be used to perform data migration and cleanup for the **DataStore2 module**, which uses the **"Berezaa Method"** of storing data. An example configuration and callback files are provided
to meet this exact use case in the `examples` folder in the tool.

**Provided Files in `examples/`**

- **`ds2-config.json`**: A set of configurations specifically tuned for a DataStore2 migration and deletion batch process.
- **`ds2-migrate.luau`**: A callback script that migrates the latest version from the DataStore2 data store to the migrated data store
- **`ds2-migrate-delete.luau`**: A callback script that **1\)** migrates the latest version from the DataStore2 data store to the migrated data store, and **2\)** deletes **all but the latest version** from the DataStore2 data store. We recommend using this script, since it will enable rollbacks in emergencies.
- **`ds2-migrate-delete-all.luau`**: A callback script that **1\)** migrates the latest version from the DataStore2 data store to the migrated data store, and **2\)** deletes **all data** from the
  DataStore2 data store, including the Data Store resource. Use this script with caution.

**Prerequisites:**

1. Integrate the **DataStore2 Migration Tool** into your experience.
2. Ensure the "Saving Method" is `MigrateOrderedBackups` (and set it if not).
3. Follow the testing instructions provided in the [**Data Stores Migration Packages Dev Forum Post**](https://devforum.roblox.com/t/datastores-migration-packages-for-the-berezaa-method-and-datastore2-module-public-beta/3631514).
4. Publish the experience with these changes.

**Execution Steps:**

1. Complete the setup in the **Getting Started** section.
2. If you are using the `ds2-migrate-delete-all.luau` callback, see **Appendix E: Configuring Data Store Deletion Callback** for more specific setup instructions.
3. Update the provided `ds2-config.json` file with your preferred callback (`ds2-migrate[-delete[-all]].luau`), `universeId`, `placeId`, and the DataStore2 prefix. The DataStore2 prefix is the name of the key / master key of your data store, followed by a ‘/’. For example, if you have a master key called `DATA`, then the prefix will be `DATA/`. We recommend verifying you have the correct prefix by looking for data stores with the pattern `<prefix><user id>` in Data Stores Manager.
4. (Optional) If you are using a custom migration scope in the [**DataStore2 Migration Tool**](https://create.roblox.com/store/asset/82521207271039/BETA-DataStore2-Migration-Tool?keyword=datastore2&pageNumber=1&pagePosition=0), edit the chosen callback script and add the scope as the value of `MIGRATED_DS_SCOPE`.
5. Run the `process-data-stores` command, e.g.  
   `lune run batch-process process-data-stores DS2_Migration_June17 -c examples/ds2-config.json`

### **9.3. Specific Example: Generic Berezaa Method Migration**

If you have implemented the “Berezaa Method” with a custom implementation, it is still viable to use this tool for data migration. Utilize the functions available in the [**Berezaa Method Data Migration Tool**](https://create.roblox.com/store/asset/100741523916104/BETA-Berezaa-Method-Data-Migration-Tool) and adjust them to your use case.

## **Appendix**

### **Appendix A: API Key Permissions**

| API System                  | Experience Operations                                                                                                                               |
| :-------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------- |
| **luau-execution-sessions** | write                                                                                                                                               |
| **memory-stores**           | memory-store.sorted-map read<br/>memory-store.sorted-map write                                                                                      |
| **ordered-data-stores**     | universe.ordered-data-store.scope.entry:read                                                                                                        |
| **universe-datastores**     | universe-datastores.objects:list<br/>universe-datastores.objects:read<br/>universe-datastores.objects:create<br/>universe-datastores.control:create |

### **Appendix B: Configuration Glossary**

_Table of all command-line options, grouped by category._

#### **Tool Behavior Options**

| Config Name | Option           | Description                                                                                                       |
| :---------- | :--------------- | :---------------------------------------------------------------------------------------------------------------- |
| config      | `-c`, `--config` | Filepath to a JSON configuration file. Configurations in this file are overridden by direct command-line options. |

#### **Shared (Required) Configurations**

_These configurations are required for all commands except resume (`universeId` only). For resume, `numProcessingInstances` and `outputDirectory` can both be changed, but are no longer considered required._

| Config Name            | Option                             | Description                                                                                                                                                                                                                                         |
| :--------------------- | :--------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| callback               | `-C`, `--callback`                 | Filepath to the Luau callback function to execute for each item.                                                                                                                                                                                    |
| numProcessingInstances | `-i`, `--num-processing-instances` | Number of Stage 2 processing sessions to run concurrently. Please note that the batch process will only spin up as many concurrent sessions as are available. So, if no sessions are running, the effective range of this configuration is 1 \- 9\. |
| outputDirectory        | `-o`, `--output-directory`         | Directory where output files will be created.                                                                                                                                                                                                       |
| placeId                | `-p`, `--place-id`                 | The Place ID of the place to execute the batch process on.                                                                                                                                                                                          |
| universeId             | `-u`, `--universe-id`              | The Universe ID of the experience to execute the batch process on.                                                                                                                                                                                  |

#### **Shared (Optional) Configurations**

_These configurations can be used with both process-keys and process-data-stores. They are optional to provide._

_The default values are suitable for most simple migration or deletion tasks. For more complex or performance-intensive operations, you should tune these values. Either way, it is recommended to understand what each configuration does before running a batch process._

| Config Name              | Option                          | Default | Description                                                                                                                          |
| :----------------------- | :------------------------------ | :------ | :----------------------------------------------------------------------------------------------------------------------------------- |
| errorLogMaxLength        | `--error-log-max-length`        | 50      | Maximum character length of error logs to persist from failed items.                                                                 |
| jobQueueMaxSize          | `--job-queue-max-size`          | 20      | Maximum number of jobs to hold in the queue at one time.                                                                             |
| maxItemsPerJob           | `--max-items-per-job`           | 50      | Maximum number of items to process in one job. Note that if `excludeDeletedKeys`                                                     |
| maxTotalFailedItems      | `--max-total-failed-items`      | 100     | Number of failed items that will cause the entire batch process to fail.                                                             |
| memoryStoresExpiration   | `--memory-stores-expiration`    | 3888000 | Expiration time in seconds for all memory store entries related to the process.                                                      |
| memoryStoresStorageLimit | `--memory-stores-storage-limit` | \-1     | Storage limit for memory stores (in kilobytes) (-1 for no limit).                                                                    |
| numRetries               | `--num-retries`                 | 4       | Number of times to retry processing a single item before marking it as failed.                                                       |
| processItemRateLimit     | `--process-item-rate-limit`     | 50      | Maximum number of items a single processing instance can process per minute.                                                         |
| progressRefreshTimeout   | `--progress-refresh-timeout`    | 5       | Interval in seconds for the Stage 1 session to timeout between updating the overall process state and listing jobs to the job queue. |
| retryExponentialBackoff  | `--retry-exponential-backoff`   | 2       | The multiplier for exponential backoff on retry timeouts. 1 for no backoff.                                                          |
| retryTimeoutBase         | `--retry-timeout-base`          | 0.5     | The base timeout in seconds for retries. `Total wait = base * (backoff ^ retry_attempt)`.                                            |

#### **`process-keys` Specific Configurations**

| Config Name        | Option                                                      | Description                                                                                                     |
| :----------------- | :---------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------- |
| allScopes          | `--all-scopes` (flag)                                       | Flag to scan all data stores scopes. If this flag is provided, the `dataStoreScope` configuration is discarded. |
| dataStoreName      | `-d`, `--data-store-name`                                   | Name of the data store to scan.                                                                                 |
| dataStoreScope     | `-s`, `--data-store-scope`                                  | Scope of the keys to scan. If not provided, defaults to global scope.                                           |
| keyPrefix          | `-P`, `--key-prefix`                                        | Prefix of keys to include in the scan. If not provided, all keys are scanned.                                   |
| excludeDeletedKeys | `--exclude-deleted-keys` / `--include-deleted-keys` (flags) | Flag to include or exclude deleted keys from the scan. Defaults to false (deleted keys are included).           |

#### **`process-data-stores` Specific Configurations**

| Config Name     | Option                      | Description                                   |
| :-------------- | :-------------------------- | :-------------------------------------------- |
| dataStorePrefix | `-P`, `--data-store-prefix` | Prefix of data stores to include in the scan. |

### **Appendix C: Custom Callback Function**

To execute a batch process, you must provide a filepath to a Luau file containing your custom callback function. This file must meet the following requirements:

1. It must contain valid, compilable Luau code.
2. It must return a single function that accepts one parameter: the item name (which will be a key name or a data store name, depending on the command).

We recommend the following format for your callback function:

```luau
-- Define Services + Other Global Variables
local DataStoreService = game:GetService("DataStoreService")
local MY_CONSTANT = 100
...

-- Define helper functions
local function migrateHelper(item)
	...
end
...


----------- EITHER -----------

return function(item)
	...
	migrateHelper(item)
	...
end

------------- OR -------------

local function callback(item)
	...
	migrateHelper(item)
	...
end

return callback
```

The callback will be validated for syntax errors on the command line prior to starting your batch process. It is ultimately up to you to ensure the callback operates as intended.

This callback runs inside a `LuauExecutionSessionTask` within your experience's context, allowing you to use `require()` on ModuleScript instances from your place’s DataModel.

**Example 1: Basic Migration**

```luau
-- example-migrate-callback.luau
local DataStoreService = game:GetService("DataStoreService")
local sourceDataStore = DataStoreService:GetDataStore("source")
local destinationDataStore = DataStoreService:GetDataStore("destination")

local function migrateValue(value)
    local migratedValue = value
    ...
    -- <INSERT MIGRATION LOGIC HERE>
    ...
    return migratedValue
end

return function(item)
    local value = sourceDataStore:GetAsync(item)
    local migratedValue = migrateValue(value)
    destinationDataStore:SetAsync(item, migratedValue)
end
```

**Example 2: Using a ModuleScript from your Place**

```luau
-- example-migrate-callback-with-module-script.luau
local MigrationScript = require(game.ServerScriptService.MigrationScript)

return function(item)
    MigrationScript.MigrateItem(item)
end
```

**Example 3: Basic Deletion**

```luau
-- example-delete-callback.luau
local DataStoreService = game:GetService("DataStoreService")
local dataStoreToDelete = DataStoreService:GetDataStore("<INSERT DATA STORE NAME>", "<INSERT DATA STORE SCOPE>")

return function(item)
	dataStoreToDelete:RemoveAsync(item)
end
```

**Example 4: Invalid Callback Function (Bad Luau Code)**

```luau
-- example-bad-luau-code.luau
local DataStoreService = game:GetService("DataStoreService")
local sourceDataStore = DataStoreService:GetDataStore("source")
local destinationDataStore = DataStoreService:GetDataStore("destination")

local function migrateValue(value)
    local migratedValue = value
    ...
    -- <INSERT MIGRATION LOGIC HERE>
    ...
    return migratedValue
end

return function(item)
    local value = sourceDataStore:GetAsync(item)
    local migratedValue = migrateValue(value)
    destinationDataStore:SetAsync(item, migratedValue)

-- syntax error - function is missing 'end' to close
```

**Example 5: Invalid Callback Function (No Function Returned)**

```luau
--example-no-function-returned.luau
local DataStoreService = game:GetService("DataStoreService")
local sourceDataStore = DataStoreService:GetDataStore("source")
local destinationDataStore = DataStoreService:GetDataStore("destination")

local function migrateValue(value)
	local migratedValue = value
    ...
    -- <INSERT MIGRATION LOGIC HERE>
    ...
    return migratedValue
end

local function callback(item)
	local value = sourceDataStore:GetAsync(item)
    local migratedValue = migrateValue(value)
    destinationDataStore:SetAsync(item, migratedValue)
end

-- 'callback' is never returned - 'return callback' would make this valid
```

The callback function will have the following predictable logging behavior:

- Any `print()` statements in your callback will appear in the session logs.
- When an error is thrown within the callback, it will trigger the retry logic. If all retries are exhausted:
  - The truncated error will attempt to be logged to `failed_items.output` file for quick reference.
  - The complete error will be logged to the full session logs.

Remember that your callback will be called on each item individually, and runs independently of other items in the same batch or different batches.

### **Appendix D: Reserved Memory Stores / Data Stores Names**

The batch processor will utilize the following memory stores / data stores resources:

| Resource Type            | Resource Names                                                                                                                                                                                                                                                                                      |
| :----------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **MemoryStoreSortedMap** | `_RBX_batch-processes`<br/>`_RBX_batch-process-storage-pool`<br/>`_RBX_batch-process-task-status`<br/>`_RBX_batch-process-guid-to-session-paths`<br/>`_RBX_batch-process-api-key-validation`<br/>`_RBX_batch-process-pages-<process name>`<br/>`_RBX_batch-process-failed-item-logs-<process name>` |
| **MemoryStoreQueue**     | `_RBX_batch-process-job-queue-<process name>`                                                                                                                                                                                                                                                       |
| **OrderedDataStore**     | `_RBX_batch-process-failed-items-<process name>`                                                                                                                                                                                                                                                    |
| **DataStore**            | `_RBX_batch-processes`<br/>`_RBX_batch-process-api-key-validation`                                                                                                                                                                                                                                  |

**Please do not write to these resources from outside of the batch processor**. Doing so may break the batch processor.

### **Appendix E: Configuring Data Store Deletion Callback**

To use the `ds2-migrate-delete-all.luau` callback, we must configure the Universe ID within the callback, and store our API key in a secret.

1. In the `ds2-migrate-delete-all.luau` file, manually add your Universe ID as the value of `UNIVERSE_ID` on **Line 11**.
2. Create a new Open Cloud API Key, and add the permission `universe-datastores.control:delete` to it for your experience.
3. Add a secret called `DS_DELETION_API_KEY` to [Secrets Store](https://create.roblox.com/docs/cloud-services/secrets), with this API Key as your value.

### **Appendix F: Tips and Tricks**

- **Use a High-Uptime Environment**: Because the CLI must remain running for the entire duration of a batch process, it is highly recommended to run the tool on a machine with a stable internet connection and high uptime, such as a Virtual Private Server (VPS), rather than a personal laptop that may go to sleep or lose connectivity.
- **Securely Manage API Keys**: Your Open Cloud API Key is a powerful secret that provides direct access to your experience's data. It is critical to protect it.
  - We strongly advise using a dedicated secret management solution, such as the [1Password CLI](https://developer.1password.com/docs/cli/get-started/), to inject your API key into the environment.
    This prevents the key from being saved in plain text.
  - If you do set the key manually (e.g., `export API_KEY=...`), be aware that this command may be saved to your shell's history file (like `.bash_history` or `.zsh_history`). To prevent accidental leaks, we recommend clearing your shell history after your session is complete.
  - When debugging session logs by calling Open Cloud endpoints, you must include your API key in the request header. To avoid pasting your key directly into browser-based API tools, consider using a browser extension (like ModHeader) to securely inject the `x-api-key` header into your requests.

### **Appendix G: Resources**

- [DataStore2 Module](https://kampfkarren.github.io/Roblox/)

- [Data Stores Documentation](https://create.roblox.com/docs/cloud-services/data-stores)

  - [Data Stores Limits](https://create.roblox.com/docs/cloud-services/data-stores/error-codes-and-limits#limits)
  - [Data Stores Manager](https://create.roblox.com/docs/cloud-services/data-stores/data-stores-manager)
  - [Data Stores Observability Dashboard](https://create.roblox.com/docs/cloud-services/data-stores/observability)

- [Data Stores Migration Packages \- Dev Forum](https://devforum.roblox.com/t/datastores-migration-packages-for-the-berezaa-method-and-datastore2-module-public-beta/3631514)

  - [\[BETA\] DataStore2 Migration Tool](https://create.roblox.com/store/asset/82521207271039/BETA-DataStore2-Migration-Tool?keyword=datastore2&pageNumber=1&pagePosition=0)
  - [\[BETA\] Berezaa Method Data Migration Tool](https://create.roblox.com/store/asset/100741523916104/BETA-Berezaa-Method-Data-Migration-Tool)

- [Lune Documentation](https://lune-org.github.io/docs)

  - [Installation](https://lune-org.github.io/docs/getting-started/1-installation)

- [Memory Stores Documentation](https://create.roblox.com/docs/cloud-services/memory-stores)

  - [Memory Stores Limits](https://create.roblox.com/docs/cloud-services/memory-stores#limits-and-quotas)
  - [Memory Stores Observability Dashboard](https://create.roblox.com/docs/cloud-services/memory-stores/observability)

- [Open Cloud Engine API for Luau Execution \- Dev Forum](https://devforum.roblox.com/t/beta-open-cloud-engine-api-for-executing-luau/3172185)

- [Roblox Creator Hub \- API Keys](https://create.roblox.com/dashboard/credentials?id=6680476435&activeTab=ApiKeysTab)

- [Roblox Open Cloud API Documentation](https://create.roblox.com/docs/cloud)

  - [LuauExecutionSessionTasks](https://create.roblox.com/docs/cloud/reference/LuauExecutionSessionTask)

- [Secrets Store](https://create.roblox.com/docs/cloud-services/secrets)
