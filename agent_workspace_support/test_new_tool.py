
import os
from . import new_tool_wrapper

class TestNewTool:
    def test(self):
        print('Running test for new tool')

if __name__ == '__main__':
    new_tool_wrapper = __import__('new_tool_wrapper')
    test_new_tool = TestNewTool()
    test_new_tool.test()