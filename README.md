
# Azure VM Availability Zone Migration Script

This script simplifies the process of migrating an Azure Virtual Machine (VM) from an **Availability Set** or a specific Availability Zone to another Availability Zone while maintaining the same VM name, resource group, network interface, and other configurations. The script leverages **Azure Backup Vault** for rollback safety and uses disk snapshots to ensure data integrity during migration.

## Features

- **Automatic Rollback Support**: Creates an on-demand backup in the Azure Backup Vault for recovery.
- **Snapshot-Based Migration**: Utilizes snapshots for OS and data disks, ensuring seamless migration without data loss.
- **Preserves Configuration**: Retains the VM name, size, network interface, and tags.
- **Zone Selection**: Allows migration to a specified Availability Zone.
- **Automated Cleanup**: Removes old snapshots and disks after successful migration.

---

## Prerequisites

1. **Azure CLI** installed and authenticated. [Install Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
2. A configured **Azure Backup Vault** for storing on-demand backups.
3. Sufficient permissions for managing Azure resources.

---

## Usage

Run the script with the following parameters:

```bash
./migrate_vm.sh \
  -g <resource-group> \
  -n <vm-name> \
  -z <new-availability-zone> \
  -l <location> \
  -v <backup-vault-name>
```

### Parameters

- `-g <resource-group>`: Resource group of the VM.
- `-n <vm-name>`: Name of the VM to be migrated.
- `-z <new-availability-zone>`: Target Availability Zone (e.g., `1`, `2`, or `3`).
- `-l <location>`: Azure region where the VM is located (e.g., `eastus`).
- `-v <backup-vault-name>`: Name of the Azure Backup Vault.

---

## Example

```bash
./migrate_vm.sh \
  -g my-resource-group \
  -n my-vm \
  -z 2 \
  -l eastus \
  -v my-backup-vault
```

This command migrates the VM `my-vm` in the `my-resource-group` to Availability Zone `2` within the `eastus` region, while creating an on-demand backup in the `my-backup-vault`.

---

## How It Works

1. **Backup and Deallocation**:
   - Stops the VM.
   - Initiates an on-demand backup in the specified Azure Backup Vault.
2. **Snapshot Creation**:
   - Creates snapshots of the OS and data disks.
3. **Disk and VM Recreation**:
   - Recreates the OS and data disks in the new Availability Zone.
   - Deletes the original VM and recreates it in the new Availability Zone with preserved configurations.
4. **Cleanup**:
   - Removes old disks and snapshots after a successful migration.

---

## Safety Measures

- The script halts on errors (`set -e`) to avoid partial execution.
- It verifies and waits for key operations (e.g., backup, snapshot creation) to complete before proceeding.
- Retains backups for **7 days** in the Azure Backup Vault.

---

## Notes

- Ensure the **Azure Backup Vault** is set up correctly before running the script.
- The script cleans up old resources only if the migration is successful. Manual cleanup may be required in case of errors.
- Some VM configurations (e.g., ultra disks) might require additional setup.

---

## Contribution

Feel free to submit issues or improvements for the script! Contributions from the community are welcome to make this migration tool even more robust.

---

**Disclaimer**: This script is provided as-is. Test it in a non-production environment before using it in production scenarios.

---

## License

This script is licensed under the **MIT License**. See the `LICENSE` file for details.

---

## Author

Developed by **Jeanclei**.

For questions or contributions, feel free to reach out!

---
