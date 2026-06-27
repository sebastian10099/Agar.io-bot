import time

class NewHelperTool:
    def __init__(self):
        self.output = []

    def run(self):
        for i in range(5):
            print(f'Iteration {i+1}')
            self.output.append(i)
        return self.output

    def get_output(self):
        return self.output