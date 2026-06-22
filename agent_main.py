
import logging
import track_task_result
def test_function():
    import subprocess
    result = subprocess.run(['/root/local_agent/agent_workspace/basics_test_helper.sh', 'execute_task_function'], capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr)
    else:
        logging.info('Task executed successfully')

def test_helpers():
    import basics_test_helper
    return basics_test_helper.execute_task_function()

# ... Rest des Skripts ...